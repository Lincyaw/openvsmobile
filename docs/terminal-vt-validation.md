# Terminal VT Validation

This checklist is the merge gate for terminal parser, renderer, input, and bridge changes.
Any PR that changes terminal VT behavior must add or update at least one related fixture regression.

## Automated fixture matrix

Fixture assets live in `app/test/fixtures/terminal/`.

| Fixture | Scenario | Automated coverage |
| --- | --- | --- |
| `zellij_startup.base64` | zellij welcome screen in alternate buffer | emulator replay, renderer replay, provider replay |
| `zellij_pane_tab_cycle.base64` | zellij pane/tab switch then exit back to shell | emulator replay |
| `tmux_status_restore.base64` | tmux status bar after detach/reattach restore | emulator replay |
| `vim_edit_exit.base64` | vim enter, edit, exit, restore shell backlog | emulator replay, provider replay |
| `neovim_edit_exit.base64` | neovim insert mode, write, exit, restore shell backlog | emulator replay |
| `htop_refresh_exit.base64` | htop dynamic refresh, exit, restore shell backlog | emulator replay |

## Required automated commands

Run these from `app/`:

```bash
flutter test \
  test/terminal/terminal_emulator_test.dart \
  test/providers/terminal_provider_test.dart \
  test/widgets/terminal_renderer_test.dart \
  test/widgets/terminal_pane_test.dart \
  test/widgets/terminal_screen_test.dart
```

## Manual acceptance checklist

### 1. Zellij startup and navigation

1. Open the app and attach to a fresh terminal session.
2. Launch `zellij`.
3. Confirm the welcome screen renders without broken ANSI spans or cursor drift.
4. Create or switch pane/tab once.
5. Exit zellij and confirm the shell backlog is restored instead of leaving stale alternate-screen content.

Pass when:
- the welcome text is readable;
- pane/tab switches do not corrupt the grid;
- exiting returns to the main shell buffer.

### 2. tmux restore

1. Launch `tmux`.
2. Create at least one extra window.
3. Detach and reattach from the mobile client.
4. Confirm the status bar remains visible and aligned after restore.

Pass when:
- window labels remain readable;
- the status bar stays pinned to the bottom row;
- restore does not clear the existing backlog unexpectedly.

### 3. vim / neovim edit flow

1. Launch `vim notes.txt` or `nvim init.lua`.
2. Enter insert mode and type a short edit.
3. Save and quit.
4. Confirm the shell prompt and saved-output message are visible after exit.

Pass when:
- alternate-screen content renders correctly while the editor is open;
- save/quit returns to the shell backlog cleanly;
- no stale status line remains after exit.

### 4. htop refresh

1. Launch `htop`.
2. Wait for at least one refresh cycle.
3. Resize the terminal once if possible.
4. Exit and confirm the shell prompt returns.

Pass when:
- refresh updates replace old rows instead of duplicating them;
- resize does not leave partial frames behind;
- exiting restores the main shell buffer.

## Failure hints

Common regression symptoms:
- ANSI style spans bleed into following text.
- Alternate-screen apps exit but stale content remains visible.
- Reattach replay triggers a reply storm back to the runtime.
- Status bars drift after resize or detach/reattach.
- Dynamic TUIs duplicate frames instead of redrawing in place.

If one of these fails, add or update the closest fixture before changing parser or renderer logic.
