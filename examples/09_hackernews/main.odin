// A Hacker News reader: the front page, newest stories and Ask HN, fetched from the Algolia API
// with `curl` on a background task. Click a title to open it, a comment count to open the thread.
//
// The network work follows the library's rule: only `update` starts side work, tasks may not touch
// the state, and their results come back as messages. Every fetch carries the generation it was
// started for, so a slow answer for a tab the user already left is dropped (and freed) instead of
// replacing the list.
package hackernews

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- State ----

Tab :: enum {
	Top,
	New,
	Ask,
}

TABS := [Tab]string{.Top = "Top", .New = "New", .Ask = "Ask"}

Story :: struct {
	id:       string, // the HN item id
	title:    string,
	url:      string, // empty for Ask HN, which has only its item page
	domain:   string,
	author:   string,
	points:   int,
	comments: int,
	created:  i64, // unix seconds
}

State :: struct {
	tab:     Tab,
	gen:     int, // the fetch generation; results from older ones are ignored
	loading: bool,
	error:   string,
	job:     ui.Task_Id,
	stories: []Story, // owned by the state; replaced as a whole on every fetch
}

// ---- Messages ----

Refresh :: struct {}
Select_Tab :: distinct Tab
Link :: struct {
	url: string, // a story's URL, or
	id:  string, // the item whose thread page to open
}

// From the background task.
Fetched :: struct {
	gen:     int,
	stories: []Story,
}
Fetch_Failed :: struct {
	gen:    int,
	reason: string,
}
Ignored :: struct {}

Msg :: union {
	Refresh,
	Select_Tab,
	Link,
	Fetched,
	Fetch_Failed,
	Ignored,
}

// ---- update ----

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Refresh:
		reload(s, fx)

	case Select_Tab:
		if s.tab == Tab(m) {
			return
		}
		s.tab = Tab(m)
		reload(s, fx)

	case Link:
		// Build the URL here, where its memory is owned and stable: the story may be replaced (or
		// the slice freed) long before the task runs. The task frees the copy when it is done.
		url := strings.clone(m.url)
		if url == "" {
			delete(url)
			url = fmt.aprintf("https://news.ycombinator.com/item?id=%s", m.id)
		}
		ui.start_task(fx, open_url, url)

	case Fetched:
		if m.gen != s.gen {
			free_stories(m.stories)
			return
		}
		free_stories(s.stories)
		s.stories = m.stories
		s.loading = false
		s.job = 0

	case Fetch_Failed:
		if m.gen != s.gen {
			return
		}
		s.loading = false
		s.job = 0
		replace(&s.error, m.reason)

	case Ignored:
	}
}

@(private)
reload :: proc(s: ^State, fx: ^ui.Effects(Msg)) {
	s.gen += 1
	s.loading = true
	replace(&s.error, "")
	if s.job != 0 {
		ui.cancel_task(fx, s.job) // only a request; the stale result is filtered by `gen`
	}
	s.job = ui.start_task(fx, fetch_stories, Fetch_Args{tab = s.tab, gen = s.gen})
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	// The first frame asks for the front page; `gen` makes sure it happens once.
	if s.gen == 0 {
		ui.dispatch(d, Refresh{})
	}
	if ui.column({width = ui.grow(), height = ui.grow()}) {
		header(s, d)
		ui.divider()
		// One state, one view: the list while there is something to show, and a whole-panel state
		// only when there is not. A refresh keeps the list and says so in the header.
		switch {
		case len(s.stories) > 0:
			story_list(s, d)
		case s.error != "":
			error_view(s, d)
		case:
			loading_view()
		}
	}
}

@(private)
header :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.row({padding = {20, 10, 20, 10}, gap = 12, align_y = .Center, width = ui.grow()}) {
		ui.tag("Y", .Warning, size = 32)
		if ui.column({gap = 0}) {
			ui.text("Hacker News", .Subsection)
			ui.text("news.ycombinator.com", .Metadata, color = .Faint)
		}
		ui.spacer()
		// Refreshing or failed over an existing list: the panel stays, the header carries the state.
		if len(s.stories) > 0 {
			if s.loading {
				ui.spinner(.Info)
			} else if s.error != "" {
				if ui.row({gap = 6, align_y = .Center}) {
					ui.icon(ph.WARNING_CIRCLE, 14, color = .Error)
					ui.text("Refresh failed", .Metadata, color = .Error)
				}
			}
		}
		for tab in Tab {
			variant := ui.Button_Variant.Ghost
			if s.tab == tab {
				variant = .Primary
			}
			if ui.button(TABS[tab], variant = variant, size = .Small).clicked {
				ui.dispatch(d, Select_Tab(tab))
			}
		}
		if ui.icon_button(ph.ARROWS_CLOCKWISE, "Refresh", size = .Small, disabled = s.loading).clicked {
			ui.dispatch(d, Refresh{})
		}
	}
}

@(private)
loading_view :: proc() {
	if ui.column({width = ui.grow(), height = ui.grow(), gap = 12, align_x = .Center, align_y = .Center}) {
		ui.spinner(.Info)
		ui.text("Loading stories from Hacker News…", .Compact, color = .Muted)
	}
}

@(private)
error_view :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column({width = ui.grow(), height = ui.grow(), gap = 8, align_x = .Center, align_y = .Center}) {
		ui.icon(ph.WARNING_CIRCLE, 28, color = .Error)
		ui.text("Could not load the front page", .Section)
		if ui.column({gap = 8, align_x = .Center, width = ui.grow(max = 520)}) {
			ui.text(s.error, .Compact, color = .Muted)
		}
		if ui.button("Try again", icon = ph.ARROWS_CLOCKWISE, variant = .Outline, size = .Small).clicked {
			ui.dispatch(d, Refresh{})
		}
	}
}

@(private)
story_list :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.scroll({id = "stories", width = ui.grow(), height = ui.grow(), padding = {8, 0, 8, 24}}) {
		for story, i in s.stories {
			story_row(story, i, d)
		}
	}
}

@(private)
story_row :: proc(st: Story, i: int, d: ui.Dispatch(Msg)) {
	if ui.column({id = st.id, width = ui.grow()}) {
		if ui.row({padding = {14, 10, 14, 10}, gap = 12, align_y = .Start, width = ui.grow()}) {
			ui.text(fmt.tprintf("%d.", i + 1), .Metadata, color = .Faint, width = ui.fixed(28), wrap = false)
			if ui.column({gap = 4, width = ui.grow()}) {
				if title := ui.text(st.title, .Body, size = 14, width = ui.grow(), interactive = true); title.clicked {
					ui.dispatch(d, Link{url = st.url, id = st.id})
				}
				if ui.row({gap = 8, align_y = .Center, wrap = true}) {
					if st.domain != "" {
						ui.icon(ph.GLOBE, 12, color = .Faint)
						ui.text(st.domain, .Metadata, color = .Muted, wrap = false)
					}
					ui.icon(ph.CARET_UP, 12, color = .Faint)
					ui.text(fmt.tprintf("%d", st.points), .Metadata, color = .Faint, wrap = false)
					ui.text("by", .Metadata, color = .Faint, wrap = false)
					ui.text(st.author, .Metadata, color = .Muted, wrap = false)
					ui.text(ago(st.created), .Metadata, color = .Faint, wrap = false)
					comments := fmt.tprintf("%d comments", st.comments)
					if st.comments == 0 {
						comments = "discuss"
					}
					if c := ui.text(comments, .Metadata, color = .Muted, wrap = false, interactive = true); c.clicked {
						ui.dispatch(d, Link{id = st.id})
					}
				}
			}
		}
		ui.divider()
	}
}

// ---- Background tasks ----

Fetch_Args :: struct {
	tab: Tab,
	gen: int,
}

fetch_stories :: proc(t: ^ui.Task_Context(Msg), args: Fetch_Args) -> Msg {
	command := []string{"curl", "-sS", "-L", "--max-time", "20", endpoint(args.tab)}

	state, out, errout, err := os.process_exec({command = command}, context.allocator)
	defer delete(out)
	defer delete(errout)

	if ui.cancelled(t) {
		return Ignored{}
	}
	if err != nil {
		return Fetch_Failed {
			gen = args.gen,
			reason = "Could not run curl",
		}
	}
	if state.exit_code != 0 {
		return Fetch_Failed {
			gen = args.gen,
			reason = fmt.aprintf("curl: %s", strings.trim_space(string(errout))),
		}
	}

	hits: Hits
	if jerr := json.unmarshal(out, &hits, allocator = context.allocator); jerr != nil {
		return Fetch_Failed {
			gen = args.gen,
			reason = fmt.aprintf("Could not read the response: %v", jerr),
		}
	}

	stories := make([]Story, len(hits.hits))
	for hit, i in hits.hits {
		stories[i] = Story {
			id       = hit.objectID,
			title    = hit.title,
			url      = hit.url,
			domain   = domain_of(hit.url),
			author   = hit.author,
			points   = hit.points,
			comments = hit.num_comments,
			created  = hit.created_at_i,
		}
	}
	// The hit records are copied; their strings belong to the stories now.
	delete(hits.hits)

	if ui.cancelled(t) {
		free_stories(stories)
		return Ignored{}
	}
	return Fetched{gen = args.gen, stories = stories}
}

// Opened with the same `open` command the desktop itself uses.
open_url :: proc(t: ^ui.Task_Context(Msg), url: string) -> Msg {
	defer delete(url)
	state, out, errout, err := os.process_exec({command = {"open", url}}, context.allocator)
	delete(out)
	delete(errout)
	_ = state
	_ = err
	return Ignored{}
}

@(private)
endpoint :: proc(tab: Tab) -> string {
	switch tab {
	case .Top:
		return "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=60"
	case .New:
		return "https://hn.algolia.com/api/v1/search_by_date?tags=story&hitsPerPage=60"
	case .Ask:
		return "https://hn.algolia.com/api/v1/search?tags=ask_hn&hitsPerPage=60"
	}
	return ""
}

// The JSON we need; unknown fields are skipped, so nothing else is allocated.
Hits :: struct {
	hits: []Hit,
}

Hit :: struct {
	objectID:     string,
	title:        string,
	url:          string,
	author:       string,
	points:       int,
	num_comments: int,
	created_at_i: i64,
}

@(private)
domain_of :: proc(url: string) -> string {
	if url == "" {
		return ""
	}
	rest := strings.trim_prefix(url, "https://")
	rest = strings.trim_prefix(rest, "http://")
	rest = strings.trim_prefix(rest, "www.")
	if i := strings.index_byte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	return strings.clone(rest)
}

@(private)
ago :: proc(unix: i64) -> string {
	now := time.time_to_unix(time.now())
	seconds := max(now - unix, 0)
	switch {
	case seconds < 60:
		return "just now"
	case seconds < 3600:
		return fmt.tprintf("%dm", seconds / 60)
	case seconds < 86400:
		return fmt.tprintf("%dh", seconds / 3600)
	case:
		return fmt.tprintf("%dd", seconds / 86400)
	}
}

@(private)
replace :: proc(dst: ^string, src: string) {
	old := dst^
	dst^ = strings.clone(src)
	delete(old)
}

@(private)
free_stories :: proc(stories: []Story) {
	for st in stories {
		delete(st.id)
		delete(st.title)
		delete(st.url)
		delete(st.domain)
		delete(st.author)
	}
	delete(stories)
}

@(private)
state_destroy :: proc(s: ^State) {
	free_stories(s.stories)
	delete(s.error)
}

main :: proc() {
	window := ui.open_window({title = "Hacker News", size = {1000, 780}})
	store: ui.Store(State, Msg)
	ui.store_init(&store, &window, State{}, update, destroy = state_destroy)
	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
	ui.store_destroy(&store)
	ui.close_window(&window)
}
