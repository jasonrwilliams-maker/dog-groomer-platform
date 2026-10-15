r"""Take every picture the SOP shows, fresh from the app.

Run it from the sop/ folder whenever the app's screens change:

    .venv\Scripts\python _scripts\screenshots.py            every picture
    .venv\Scripts\python _scripts\screenshots.py dog-card   only the ones whose file name has "dog-card"

It opens the app in Microsoft Edge without showing a window, taps through to
each screen in SHOTS below, and saves the picture over the file the manual
already points at in screenshots/. Then `quarto render` shows the new ones.

Most pictures come from the browser demo, which needs nothing running. The
demo has no Admin, so the Admin pictures come from the shop's own app on this
computer (`docker compose up -d` in the repo, then http://localhost:3000). If
that isn't running, those pictures are skipped and the old ones stay.

One-time setup, from sop/ (screenshots/README.md has the rest):
    python -m venv .venv
    .venv\Scripts\python -m pip install playwright
"""

import re
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

SOP = Path(__file__).resolve().parent.parent
PICTURES = SOP / "screenshots"

# Where each picture is taken from.
SITES = {
    "demo": "https://jasonrwilliams-maker.github.io/dog-groomer-platform/",
    "local": "http://localhost:3000/",
}


@dataclass
class Shot:
    file: str                       # where it goes, inside screenshots/
    steps: list = field(default_factory=list)   # what to tap, in order (see STEPS)
    ready: str = ""                 # words on screen that mean it's finished drawing
    site: str = "demo"              # "demo" or "local" (see SITES)
    size: tuple = (1280, 800)       # the window, width x height
    whole_page: bool = False        # True: the full length of the page, not just the window


# Every picture in the manuals. To add one: copy a line, give it the file name
# the module uses, and list the taps that get to that screen. The steps are:
#   ("tap", "Words on the button")
#   ("tap_exact", "+ Add")   the button whose words are exactly these, when
#                            "tap" would find a longer one first
#   ("search", "what to type in the dog search")
#   ("wait", "words that appear on the next screen")
#   ("week_ahead", "Day")    put the date a week from today in the box with
#                            this label, so a booking shows free times
SHOTS = [
    Shot("shared/welcome.png", ready="Who's grooming?", size=(900, 640)),
    Shot("groomer/dog-list.png", steps=[("tap", "Tanya")], ready="+ New client"),
    # Jaddi: his rabies has run out, so the vaccine line shows the stop.
    Shot("groomer/dog-card.png", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi")],
         ready="Rabies"),
    Shot("groomer/new-client.png", steps=[("tap", "Tanya"), ("tap", "New client")], ready="Save and add paperwork"),
    Shot("groomer/edit-profile.png", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"),
                                            ("tap", "Edit profile")], ready="Save changes"),
    # The demo keeps no copies, so its Add paperwork goes straight to typing the
    # dates in; the photo-or-file choice only shows in the shop's own app.
    Shot("groomer/paperwork-start.png", site="local", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"),
                                               ("tap", "Add paperwork")], ready="Type the dates in"),
    Shot("groomer/paperwork-typed.png", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"),
                                               ("tap", "Add paperwork")],
         ready="Not on their paperwork"),
    Shot("groomer/allergy-add.png", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"), ("tap_exact", "+ Add")],
         ready="Add allergy"),
    Shot("groomer/handling-add.png", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"),
                                            ("tap", "Add note")], ready="How hard to handle"),
    Shot("groomer/booking.png", steps=[("tap", "Tanya"), ("search", "Daisy"), ("tap", "Daisy"),
                                       ("tap", "Book a groom"), ("week_ahead", "Day")],
         ready="Free from", whole_page=True),
    Shot("groomer/calendar.png", steps=[("tap", "Tanya"), ("tap", "Calendar")], ready="Vaccine expiries"),
    # Daisy is cleared, so her groom can be started and then recorded.
    Shot("groomer/haircut.png", steps=[("tap", "Tanya"), ("search", "Daisy"), ("tap", "Daisy"),
                                       ("tap", "Start groom"), ("tap", "Record the haircut")],
         ready="Save and finish the groom", whole_page=True),
    # The demo keeps no photos, so the photo buttons only show in the shop's own app.
    Shot("groomer/dog-photo.png", site="local", steps=[("tap", "Tanya"), ("search", "Jaddi"), ("tap", "Jaddi"),
                                                       ("tap", "photo")], ready="Choose a photo"),
    Shot("manager/admin-door.png", site="local", steps=[("tap", "Nadia"), ("tap", "Admin")],
         ready="Admin is locked"),
    # Past the lock: these need Admin open, so they wait for a way to sign in
    # from the script. Until then they are placeholders.
    Shot("manager/admin-overview.png", site="local", steps=[("tap", "Nadia"), ("tap", "Admin")],
         ready="Your to-do list"),
    Shot("manager/passkeys-and-pin.png", site="local", steps=[("tap", "Nadia"), ("tap", "Admin"),
                                                              ("tap", "Passkeys and PIN")], ready="Your passkeys"),
]


# --- How each step is done ----------------------------------------------------

def words_on(words: str):
    return re.compile(r"\b" + re.escape(words) + r"\b")


def tap(page: Page, words: str):
    # The first button with these words on it.
    page.get_by_role("button", name=words_on(words)).first.click()


def tap_exact(page: Page, words: str):
    page.get_by_role("button", name=words, exact=True).first.click()


def search(page: Page, words: str):
    page.locator('input[aria-label^="Search by"]').fill(words)
    # The list follows a beat after typing; wait for the one it found.
    page.get_by_role("button", name=words_on(words)).first.wait_for()


def week_ahead(page: Page, label: str):
    import datetime
    day = datetime.date.today() + datetime.timedelta(days=7)
    while day.weekday() == 6:           # not a Sunday
        day += datetime.timedelta(days=1)
    page.get_by_label(label, exact=True).fill(day.isoformat())
    page.wait_for_timeout(1000)         # the groomers' free times follow


def wait(page: Page, words: str):
    page.get_by_text(words, exact=False).first.wait_for()


STEPS = {"tap": tap, "tap_exact": tap_exact, "search": search, "wait": wait, "week_ahead": week_ahead}

# The demo's yellow "Live demo" band across the top isn't part of the shop's
# own screens, so it's left out of the pictures.
HIDE_DEMO_BANNER = """
for (const s of document.querySelectorAll('span.font-semibold'))
  if (s.textContent.trim() === 'Live demo.') s.closest('div.border-b')?.remove();
"""


def site_is_up(url: str) -> bool:
    try:
        urllib.request.urlopen(url, timeout=3)
        return True
    except OSError:
        return False


def take(browser, shot: Shot, url: str):
    width, height = shot.size
    # A fresh window each time: nobody is remembered as signed in.
    context = browser.new_context(viewport={"width": width, "height": height}, device_scale_factor=2)
    page = context.new_page()
    page.set_default_timeout(60_000)    # the demo builds its database first
    page.goto(url)
    # The welcome screen's names only appear once the shop's records answer,
    # which in the demo means Postgres has finished loading in the page.
    page.get_by_text("Who's grooming?").wait_for()
    page.get_by_role("button").filter(has=page.locator("span[aria-hidden]")).first.wait_for()
    for step, words in shot.steps:
        STEPS[step](page, words)
    if shot.ready:
        wait(page, shot.ready)
    page.evaluate(HIDE_DEMO_BANNER)
    page.mouse.move(0, 0)               # no hover highlight on whatever was tapped last
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(500)          # let pictures and fades finish
    out = PICTURES / shot.file
    out.parent.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(out), full_page=shot.whole_page)
    context.close()


def main(only: list[str]):
    shots = [s for s in SHOTS if not only or any(o in s.file for o in only)]
    if not shots:
        sys.exit(f"No picture matches {' '.join(only)}. The names are in SHOTS in {Path(__file__).name}.")
    up = {name: site_is_up(url) for name, url in SITES.items() if any(s.site == name for s in shots)}
    taken, skipped, failed = [], [], []
    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(channel="msedge")
        except Exception:
            browser = p.chromium.launch()   # no Edge: Playwright's own (python -m playwright install chromium)
        for shot in shots:
            if not up[shot.site]:
                skipped.append(shot)
                continue
            print(f"  {shot.file} ...", end=" ", flush=True)
            try:
                take(browser, shot, SITES[shot.site])
                print("done")
                taken.append(shot)
            except Exception as e:
                print(f"didn't work: {str(e).splitlines()[0]}")
                failed.append(shot)
        browser.close()

    print(f"\n{len(taken)} picture(s) taken.")
    if skipped:
        print("Kept the old picture, because the app isn't running at " +
              ", ".join(sorted({SITES[s.site] for s in skipped})) + ":")
        for s in skipped:
            print(f"  {s.file}")
        print("Start it with `docker compose up -d` in the repo and run this again for those.")
    if failed:
        print("These didn't work (kept the old picture); the screen may have changed:")
        for s in failed:
            print(f"  {s.file}")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
