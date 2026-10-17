# Telegraph

A minimal, full-screen Telegram client written in Swift for macOS 27.
It supports a personal account's direct conversations and Saved Messages, phone-code
login with 2FA, live text messaging, and paginated history. Click `[Image]`, `[Video]`,
or `[GIF]` to download the attachment and open it with macOS Quick Look.

The executable uses only Swift and macOS system libraries. There are no Swift package
dependencies, background services, package-manager installs, or runtime resource bundles.
Telegram's protocol schema and public server keys are embedded in the binary.

## Run

Install Xcode 27 or its Swift 6.4 command-line tools, then run:

```sh
swift run -c release telegraph
```

The first launch prompts for your application **API ID** and **API hash** from
[my.telegram.org](https://my.telegram.org) → **API development tools**, your phone
number including its country code, and the login code. Enter your 2FA password if
requested. Codes can arrive in another logged-in Telegram app, SMS, a call, or an
existing login email; Telegram chooses the available method. Email setup, passkeys,
QR login, and account registration are outside this version.

Login codes, the API hash, and passwords use hidden input. Passwords and login codes
are not saved. API credentials and per-data-center authorization keys are stored in
the macOS Keychain with synchronization disabled. The client keeps message history
in memory for the current conversation.

Use a terminal at least **60 columns × 16 rows**. Direct clicks use xterm SGR or
legacy mouse reporting. Keyboard navigation works without mouse support.

| Key or action | Result |
| --- | --- |
| Tab / Shift-Tab | Cycle chat list, history, composer |
| Up / Down in chat list | Select a conversation |
| Enter in chat list | Open the conversation |
| Up / Down in history | Select an attachment |
| Enter in history | Download/open the selected attachment |
| Click an attachment label | Download/open that attachment |
| PgUp / PgDn, mouse wheel | Scroll history; load earlier messages at the top |
| Enter in composer | Send text |
| Ctrl-J | Insert a newline |
| Paste | Insert text without sending it |
| Left / Right, Ctrl-A / Ctrl-E | Move the composer cursor |
| Ctrl-U / Ctrl-W | Delete to the start / delete a word |
| Escape | Focus the chat list |
| Ctrl-L | Redraw |
| Ctrl-Z | Suspend; resume with your shell's `fg` |
| Ctrl-C / Ctrl-D | Exit |

A failed send retains the draft. Press Enter again to retry with the same Telegram
message identifier. Editing the draft creates a new identifier. Active chats are
marked read when their latest messages are visible.

Downloads are saved to `~/Downloads/Telegraph/<account-id>/`. Downloads run one at a
time, stream to temporary files, and become reusable files only after completion.
Repeated clicks during a download share the same transfer. GIF labels include
Telegram animations stored as MP4; the file keeps its actual extension.
Protected and disappearing media cannot be saved. Unsupported attachments display
a text label.

```sh
swift run -c release telegraph logout
```

Logout revokes this client's retained authorizations and removes its Keychain entry.
Downloaded files remain in Downloads. Only one process can use each account profile.

## Install a standalone executable

```sh
swift build -c release
telegraph_bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$telegraph_bin_dir/telegraph" "$HOME/.local/bin/telegraph"
```

Add `~/.local/bin` to your shell's `PATH` if needed. No resource directories need to
be copied with the executable. `telegraph --help` and `telegraph --version` also work
without an interactive terminal.

## Development and validation

```sh
swift test
TELEGRAPH_LIVE_TEST=1 swift test -c release --filter liveTestServerHandshake
```

The optional live test creates an MTProto transport key on Telegram's test server
and verifies an encrypted RPC response using an invalid application ID. It neither
logs in nor accesses an account. The normal suite uses independent arithmetic and
server-side SRP fixtures, scripted encrypted transports, temporary files, and
pseudo-terminals. It covers login migration, invalid codes, direct-chat filtering,
history, sending/retrying multiline text through the terminal, mouse/paste decoding,
terminal restoration, integrity rejection, timeouts, and download recovery.

For a manual account test, run `telegraph --test-server` with your own application
credentials and an existing Telegram test account. It uses a separate Keychain
entry, process lock, and `Downloads/Telegraph/test/` directory. Production account
login and actual media viewing require locally entered credentials and interactive
verification.

The first version excludes groups, channels, secret chats, calls, attachment uploads,
global user search, and creating new conversations. It has no persistent message
database. Only the existing direct conversations returned by Telegram are listed.

The implementation separates MTProto transport/cryptography/TL decoding, account
and messaging state, media storage, and terminal rendering. Networking and client
state use Swift actors; terminal interaction runs on the main actor.

Telegram API **layer 225** is pinned. The full JSON sources remain under
`Sources/TelegraphCore/Resources/` for inspection. After intentionally updating those
sources and the layer constant, regenerate the embedded data:

```sh
swift Tools/embed-schemas.swift
```

The maintenance script uses only system modules and is not run during a normal
build. The embedded source records SHA-256 hashes of the source data.
See [NOTICE.md](NOTICE.md) for protocol-data provenance.
