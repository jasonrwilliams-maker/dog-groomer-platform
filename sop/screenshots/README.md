# Screenshots

Every picture in the manuals, one folder per manual. You don't take these by
hand: one command opens the app, taps through to each screen, and saves each
picture over the file the manual already shows.

## Refreshing the pictures

From the `sop/` folder:

```
.venv\Scripts\python _scripts\screenshots.py
quarto render
```

To retake only some of them, add part of the file name:
`.venv\Scripts\python _scripts\screenshots.py dog-card`.

Most pictures come from the browser demo on the web, so nothing has to be
running. The demo has no Admin, so `manager/admin-door.png` comes from the
shop's own app on this computer. Start it with `docker compose up -d` in the
repo first; if it isn't running, those pictures are skipped and the old ones
stay.

The pictures inside Admin need a manager. When the command reaches them, an
Edge window opens at the Admin lock: unlock it with your own passkey or PIN
within 5 minutes. The command takes the pictures in that window and locks
Admin again.

Pictures from the shop's own app use the demo dog Bear, who has no photo:
that app also holds real photos, which stay off the published manual.

## Adding a picture

1. In the module, point at the file you want, e.g.
   `![The calendar](/screenshots/groomer/calendar.png)`.
2. In `_scripts/screenshots.py`, copy a line in `SHOTS`, give it that file
   name, and list the taps that get to the screen.
3. Run the command above.

## One-time setup

From the `sop/` folder:

```
python -m venv .venv
.venv\Scripts\python -m pip install playwright
```

It uses the Microsoft Edge already on this computer. The `.venv` folder is
not kept in git.
