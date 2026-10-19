# mdr-preview

Live Markdown preview for Emacs, in your browser, rendered by
[mdr](https://github.com/CleverCloud/mdr).

`M-x mdr-preview-mode` opens the current buffer in the browser and keeps it up
to date as you type, unsaved edits included. You get mdr's rendering: Mermaid
diagrams drawn natively as SVG, local images inlined, syntax highlighting,
search, and a table of contents that collapses as a whole or section by section.

## Requirements

- Emacs 29.1 or later
- An mdr with `--export html` and `--allow-connect`, which the package can
  download for you

### mdr

The two mdr flags are proposed upstream in
[CleverCloud/mdr#79](https://github.com/CleverCloud/mdr/pull/79). Until a
release has them, they come from the fork,
[Andsbf/mdr](https://github.com/Andsbf/mdr). Its `main` carries that PR along
with [#77](https://github.com/CleverCloud/mdr/pull/77) (fullscreen diagram
fixes) and [#78](https://github.com/CleverCloud/mdr/pull/78) (collapsible
table of contents).

**You don't have to install it yourself.** If no `mdr` on your `exec-path`
supports `--allow-connect`, turning `mdr-preview-mode` on offers to download a
prebuilt one (`M-x mdr-preview-install-mdr` does the same). The download:

- comes from the fork's
  [releases](https://github.com/Andsbf/mdr/releases), built by its CI;
- is picked for macOS (Apple silicon or Intel), Linux (x86_64 or arm64) or
  Windows (x86_64);
- is checked against SHA-256 hashes pinned in `mdr-preview.el`, so an archive
  that doesn't match is refused and nothing is installed;
- is unpacked into `~/.emacs.d/mdr-preview/<release>/`
  (`mdr-preview-install-directory`) and used only by this package. Nothing goes
  on your `PATH`.

On Linux, the prebuilt mdr also needs GTK 3 and WebKitGTK 4.1 to start, even
though the preview never opens a window. Most desktops have both; otherwise
install `libgtk-3-0` and `libwebkit2gtk-4.1-0` (Debian/Ubuntu names).

To build it yourself instead:

```sh
# Nix (the flake has no lock file, which Nix will not write for a remote flake)
nix profile add --no-write-lock-file github:Andsbf/mdr

# Cargo
cargo install --git https://github.com/Andsbf/mdr
```

An mdr on your `exec-path` that supports `--allow-connect` is preferred over
the downloaded one. To force a particular binary, set `mdr-preview-program`.

## Install

With `use-package` and the built-in `:vc` keyword (Emacs 30+):

```elisp
(use-package mdr-preview
  :vc (:url "https://github.com/Andsbf/mdr-preview")
  :bind ("C-c M" . mdr-preview-mode))
```

With [straight.el](https://github.com/radian-software/straight.el):

```elisp
(use-package mdr-preview
  :straight (:host github :repo "Andsbf/mdr-preview")
  :bind ("C-c M" . mdr-preview-mode))
```

The package binds no keys itself; pick whatever suits your config.

## Usage

| Command | Does |
|---|---|
| `mdr-preview-mode` | Toggle the live preview of the current buffer |
| `mdr-preview-browse` | Open the preview again, e.g. after closing its tab |
| `mdr-preview-install-mdr` | Download the prebuilt mdr (asked for automatically when needed) |

Turning the mode off, or killing the buffer, stops the server and marks the
browser tab "(closed)". The preview survives a change of major mode and
`revert-buffer`; a revert re-renders like any other edit. Quitting Emacs stops
the server too, but without telling the tab, which then keeps retrying until
you close it.

## Options

`M-x customize-group RET mdr-preview`:

| Option | Default | Meaning |
|---|---|---|
| `mdr-preview-program` | `nil` | The mdr executable; `nil` finds one on `exec-path`, else uses the downloaded one |
| `mdr-preview-install-directory` | `~/.emacs.d/mdr-preview/` | Where the downloaded mdr goes |
| `mdr-preview-delay` | `0.3` | Seconds of quiet after an edit before re-rendering |
| `mdr-preview-arguments` | `nil` | Extra mdr arguments, e.g. `("--offline")` or `("--theme" "dark")` |
| `mdr-preview-browse-function` | `browse-url` | How the preview's URL is opened |

## How it works

1. The buffer is piped to `mdr --export html --allow-connect -`, asynchronously,
   so a slow remote image never freezes Emacs. mdr resolves relative images
   against the buffer's directory.
2. Emacs serves the page from a small HTTP server on `127.0.0.1`, on a free port
   per buffer, and opens it in the browser.
3. 0.3s after you stop typing, the buffer is rendered again and a `reload` event
   goes out over [server-sent
   events](https://developer.mozilla.org/docs/Web/API/Server-sent_events). The
   page refetches itself and swaps the content and table of contents in place,
   so the scroll position and your folded sections hold. If the new render needs
   a script the page does not have yet (the first code block or Mermaid fallback
   of a document), it reloads instead.

### Security

- The server listens on loopback only.
- It answers only requests whose `Host` header is `127.0.0.1:<port>` or
  `localhost:<port>`, which blocks DNS-rebinding pages.
- The page keeps mdr's Content-Security-Policy. `--allow-connect` relaxes only
  `connect-src`, to `'self'`, so the page can reach this server and no other
  origin.
- mdr sanitises the document's own HTML before rendering, so scripts written
  in the document never run.

## Development

```sh
make          # byte-compile (warnings are errors), checkdoc, tests
make test     # ERT; the end-to-end tests need mdr and curl and skip without them
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
