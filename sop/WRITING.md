# How the SOP is written

Every module is written for someone who has never seen the software. Leave
nothing for the reader to work out. If a step needs them to guess where
something is, what it is called, or what happens next, it isn't finished.

## Voice

- **Instructions, not conversation.** "Click your name." Not "You'll want to
  pick your name."
- **Formal.** No contractions in instructions (*do not*, *cannot*), no asides,
  no jokes. The screen's own wording keeps its contractions: **Who's
  grooming?**, **Can't groom today**.
- **Present tense for what happens.** "The Check-in screen opens." Not "will
  open".
- **Talk to the reader.** "Click", "Type", "Read". Not "the groomer clicks".

## Steps

- **One action per numbered step.** If a step has "and" between two actions,
  split it.
- **Name every control exactly as it appears on screen, in bold:** **Switch**,
  **Add paperwork**, **Dog or owner name**.
- **Say where it is:** "at the top right of the screen", "above the search
  box", "on the left side of the Check-in screen".
- **Say what happens after each action.** Every step that changes the screen
  ends with what the reader now sees: "The dog's card opens on the right."
- **Use "click".** The app runs on tablets and computers. Each manual's first
  page says once that click means tap on a tablet.
- **Screens and areas start with a capital:** Welcome screen, Check-in screen,
  Calendar screen, Admin, the dog's card.

## Module layout

Every module follows [_template.qmd](_template.qmd), in this order:

1. **Purpose.** One sentence: what this procedure does and why.
2. **Applies to.** Who carries it out.
3. **Before you begin.** What must already be true.
4. **Procedure.** The numbered steps, with a screenshot where the screen
   changes.
5. **Result.** What the screen shows when the procedure is done correctly.
6. **If something goes wrong.** Each message the reader may see gets its own
   subsection (`###`), titled with the message exactly as the screen shows
   it, saying what it means and what to do. Each one then has its own number
   and link, so you can send someone straight to the fix.

Leave out any section with nothing in it, except Purpose, Procedure and
Result.

## Headings

Sections are numbered automatically (4 Procedure, 6.1 …) and appear in **On
this page**. Use `##` for the six sections above and `###` for anything
inside them. Do not number headings by hand.

## Names to use

Call each thing by one name, the same on every page.

| Say | Not |
|---|---|
| the shop's app | the shop app, the system, the software |
| the Welcome screen, the Check-in screen, the Calendar screen | the home page, the dog list page |
| the dog's card | the dog card, the profile page |
| Admin | the Admin panel, the Admin view |
| the Technical workbench | the records tool, the review tool, the labelling tool |
| the shop's database | the demo database (except in SYS-07, where both databases are named) |
| the Groomer manual, the Manager manual, the Technical systems manual | the systems manual |

The names of buttons and screens follow the app exactly, in bold. If the app
renames something, rename it here too.

## Module numbers

Each module has a number in its subtitle: **GRM** for the groomer manual,
**MGR** for the manager manual, **SYS** for the technical systems manual, then two
digits (GRM-01, GRM-02, …). A number is never reused, even if its module is
removed.

## Example

> **Weak:** Search for the dog by its name or the owner's name.
>
> **Strong:**
> 1. Click the **Dog or owner name** search box on the left side of the
>    Check-in screen.
> 2. Type the name of the dog, or of its owner. The list below the search box
>    shows only the dogs that match.
