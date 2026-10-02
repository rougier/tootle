# tootle.el

A tiny, text-only, read-only, emoji-free Mastodon client for Emacs.

`tootle` fetches your home timeline with an access token and renders
toots in a dedicated buffer — no images, no emoji, no posting, just a
fast way to read your feed from inside Emacs. 

If you need a real mastodon client, use the beaufitul mastodon.el
client at https://codeberg.org/martianh/mastodon.el.

## Requirements

- Emacs 29.1 or later, built with GnuTLS support
- A Mastodon access token with at least the `read` scope

## Installation

Drop `tootle.el` somewhere on your `load-path` and require it:

```elisp
(require 'tootle)
```

Or, with `use-package` and `straight.el` / `package-vc`:

```elisp
(use-package tootle
  :vc (:url "https://github.com/rougier/tootle"))
```

## Setup

Set your instance URL and access token, typically in your init file:

```elisp
(tootle-config-set :instance "INSTANCE") ;; Base URL of your mastodon instance
(tootle-config-set :token "TOKEN") ;; Read-only token
```

To get an access token: on your instance, go to
**Settings → Development → New Application**, create one with at
least the `read` scope, and copy the resulting access token.

## Usage

Run `M-x tootle` to open (or switch to) the `*tootle*` buffer. On
first call it fetches `tootle-initial-limit` toots; call it with a
numeric prefix argument (`C-u 100 M-x tootle`) to fetch that many
instead, paging as needed (mastodon API hard limit is 40 / pages).

### Keybindings

| Key     | Action                                                                 |
|---------|------------------------------------------------------------------------|
| `g`     | Refresh: fetch newer toots                                             |
| `n`     | Move to the next visible toot                                          |
| `p`     | Move to the previous visible toot                                      |
| `r`     | Fold the toot at point, mark it read, move to next unread visible toot |
| `u`     | Mark the toot at point unread, move to next read visible toot          |
| `R`     | Mark every visible toot read                                           |
| `U`     | Mark every visible toot unread                                         |
| `b`     | Browse the toot at point                                               |
| `d`     | Remove the toot at point from the local buffer                         |
| `D`     | Remove every read toot from the local buffer (with confirmation)       |
| `s`     | Filter the timeline live as you type; `RET` keeps it, `C-g` cancels    |
| `h`     | Hide every currently-read toot (combines with active text filter)      |
| `SPC`   | Clear the active filter — text search and/or hidden read toots         |
| `q`     | Bury the buffer                                                        |
| `TAB`   | Toggle the body of the toot at point                                   |
| `S-TAB` | Fold or unfold every visible toot together                             |
| `RET`   | Open the link at point                                                 |

## Configuration

| Key              | Default | Description                                               |
|------------------|---------|-----------------------------------------------------------|
| `:instance`      | `nil`   | Base URL of your Mastodon instance                        |
| `:token`         | `nil`   | Read-only access token used for authenticated requests    |
| `:initial-limit` | `50`    | Number of toots fetched on first load                     |
| `:limit`         | `20`    | Max toots per request while paging                        |
| `:timeout`       | `20`    | Max toots per request while paging                        |
| `:width`         | `nil`   | Column width used for wrapping; `nil` uses window's width |

## Limitations

- No media display (obsiously)
- No poll interaction
- No content warning handling
- No context navigation (yet)

## License

GPL-3.0-or-later. See the license header in `tootle.el` for details.

## Notes on development

This package is an experiment in "vibe-coding" with DeepSeek (free
version) and Claude (free version). I've started by asking Claude a
minimal read-only mastodon client (300 lines) that constituted the
base of this package. I then manually coded what I precisely wanted
and test the result over several weeks because the initial code was
not so good and kind of over-engineered. I then use Claude again to
add some new functions and check the result. This introduced a lot of
new bugs that were more or less complex to find and fix. In the end, I
very carefully review the code and I rewrote pretty much everything.
I'm not sure I gained any time in the process because there were a lot
of subtle errors that were hard to debug at the start mostly because I
did not write the initial code and because it was overly complex for
no obvious reason. The only thing that was useful was to show me a
read-only mastodon client can be written with 300 lines of emacs lisp.

**Note** I've been using the free version of Claude which is quite
limited in what you can ask daily. This forces you to write your own
code and only to use Claude or DepSeek for when you're really
stuck. The state of code is now mostly mine and only the async http
part remains mostly unchanged

**Conclusion** No more vibe-coding for me. I'll write everything
myself (but maybe the documentation since these LLM are pretty damn
good at writing it) because it is the only way to really get a sense
of your code. The small time saved during early development (1 day)
has been mostly lost in later maintenance tasks (1 month). If I had
started from scratch, I think I would have been much faster.

