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

The pictures inside Admin need a manager: the script opens a window at the
Admin lock and waits for you to unlock it with your own passkey or PIN. It
never types a PIN itself, and locks Admin again when it's done.

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
    unlocked: bool = False          # True: inside Admin. Its steps start from the Admin
                                    # overview, after a manager has unlocked it (see below)


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
    # Local pictures use Bear: a demo dog with no photo of its own, since the
    # shop's own app also holds real photos that stay off the published site.
    Shot("groomer/paperwork-start.png", site="local", steps=[("tap", "Tanya"), ("search", "Bear"), ("tap", "Bear"),
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
    Shot("groomer/dog-photo.png", site="local", steps=[("tap", "Tanya"), ("search", "Bear"), ("tap", "Bear"),
                                                       ("tap_exact", "Add photo")], ready="Choose a photo"),
    Shot("manager/admin-door.png", site="local", steps=[("tap", "Nadia"), ("tap", "Admin")],
         ready="Admin is locked"),
    # Inside Admin. The script never types a PIN: it opens a window at the
    # Admin lock and waits for a manager to unlock it with their own passkey
    # or PIN, then takes these in that window.
    Shot("manager/admin-overview.png", site="local", unlocked=True, ready="Your to-do list"),
    # The staff list. Nothing is saved: each picture stops at the form or the question.
    Shot("manager/staff-list.png", site="local", unlocked=True, steps=[("tap", "Staff working here")],
         ready="Add a staff member"),
    Shot("manager/staff-add.png", site="local", unlocked=True,
         steps=[("tap", "Staff working here"), ("tap", "Add a staff member")], ready="Add to the staff list"),
    # The first other manager's Reset Admin access: it needs a second manager on the staff list.
    Shot("manager/staff-reset.png", site="local", unlocked=True,
         steps=[("tap", "Staff working here"), ("tap", "Reset Admin access")], ready="Yes, reset Admin access"),
    Shot("manager/system.png", site="local", unlocked=True, steps=[("tap", "Database and backups")],
         ready="Sections in the database", whole_page=True),
    # Last: its box stays open in the green bar until Done.
    Shot("manager/passkeys-and-pin.png", site="local", unlocked=True, steps=[("tap", "Passkeys and PIN")],
         ready="Your passkeys"),
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

# The demo's yellow "Live demo" band across the top, and the shop's own app's
# developer badge, aren't part of the shop's screens, so they're left out.
HIDE_DEMO_BANNER = """
document.querySelectorAll('nextjs-portal').forEach((e) => e.remove());   // the dev server's "N" badge
for (const s of document.querySelectorAll('span.font-semibold'))
  if (s.textContent.trim() === 'Live demo.') s.closest('div.border-b')?.remove();
"""


def site_is_up(url: str) -> bool:
    try:
        urllib.request.urlopen(url, timeout=30)    # the dev server can take a while on its first page
        return True
    except OSError:
        return False


def save(page: Page, shot: Shot):
    if shot.ready:
        wait(page, shot.ready)
    page.evaluate(HIDE_DEMO_BANNER)
    page.mouse.move(0, 0)               # no hover highlight on whatever was tapped last
    page.wait_for_load_state("networkidle")
    page.wait_for_timeout(500)          # let pictures and fades finish
    out = PICTURES / shot.file
    out.parent.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(out), full_page=shot.whole_page)


def unlock_admin(p, url: str):
    """A window, shown on screen, at the Admin lock, once a manager has opened it."""
    browser = launch(p, headless=False)
    context = browser.new_context(viewport={"width": 1280, "height": 800}, device_scale_factor=2)
    page = context.new_page()
    page.goto(url)
    page.get_by_text("Who's grooming?").wait_for()
    tap(page, "Nadia")
    tap(page, "Admin")
    print("\n  Admin needs a manager. In the window that just opened, unlock Admin with")
    print("  your own passkey or PIN. The pictures are taken once it's open (5 minutes).")
    page.get_by_text("Admin open for").wait_for(timeout=300_000)
    return browser, page


def launch(p, headless=True):
    try:
        return p.chromium.launch(channel="msedge", headless=headless)
    except Exception:
        return p.chromium.launch(headless=headless)   # no Edge: Playwright's own (python -m playwright install chromium)


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
    save(page, shot)
    context.close()


def main(only: list[str]):
    shots = [s for s in SHOTS if not only or any(o in s.file for o in only)]
    if not shots:
        sys.exit(f"No picture matches {' '.join(only)}. The names are in SHOTS in {Path(__file__).name}.")
    up = {name: site_is_up(url) for name, url in SITES.items() if any(s.site == name for s in shots)}
    taken, skipped, failed = [], [], []
    with sync_playwright() as p:
        browser = launch(p)
        admin = None                        # (browser, page) once a manager has unlocked Admin
        for shot in shots:
            if not up[shot.site]:
                skipped.append(shot)
                continue
            if shot.unlocked:
                print(f"  {shot.file} ...", end=" ", flush=True)
                try:
                    admin = admin or unlock_admin(p, SITES[shot.site])
                    page = admin[1]
                    tap(page, "Admin")          # back to the overview
                    for step, words in shot.steps:
                        STEPS[step](page, words)
                    save(page, shot)
                    print("done")
                    taken.append(shot)
                except Exception as e:
                    print(f"didn't work: {str(e).splitlines()[0]}")
                    failed.append(shot)
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
        if admin:
            admin[1].get_by_role("button", name="Lock Admin").click()
            admin[0].close()

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
