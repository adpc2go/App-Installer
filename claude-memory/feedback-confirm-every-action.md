---
name: feedback-confirm-every-action
description: "every action needs an acknowledgement that it registered, then a separate confirmation it took effect - and real indicators, counting DOWN not up"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d9b40d25-5b06-4b73-9420-dacbe5207039
  modified: 2026-08-22T17:37:50.878Z
---

Every action the technician takes must answer three things, and they are not the same thing:

1. **"I pressed it"** - the press registered. Immediate, on the control or the row.
2. **"It is taking effect"** - the work is under way, with a real indicator.
3. **"It is done"** - the outcome, only once it is actually true.

An indicator has to be a real measurement: **a percentage, or time REMAINING counting down** -
never elapsed time counting up, and never a bare spinner where a number is obtainable. A spinner
says "something is happening"; it does not say how long, which is the only question being asked.

**Why:** stated 2026-08-22 while building the batch strip. The remove button had collapsed all
three into one: pressing it wrote `Removed from batch` instantly, even for an app already handed
to the elevated worker - which decides for itself and may already have started the installer. The
UI was asserting an outcome it did not own. It now says `Removing - waiting for the installer to
skip it` on the press, and only the worker's own report turns that into `Removed`. Cancel already
worked this way (`Cancelling - waiting for the current install to finish...`), which is the
pattern to copy. This is a general rule, not a note about that one button.

**How to apply:** before writing a status string, ask who owns the outcome. If this process owns
it, say it happened. If another process, the network or a vendor installer owns it, say what was
REQUESTED and let their report settle it - a status that has to be corrected afterwards is worse
than one that was honest and vague. For long operations, find a real denominator (bytes, item i
of n, bytes/sec turned into a remaining-time estimate) before settling for a spinner. Apply where
it makes sense - not every action is long enough to need stage 2.

Related: [[feedback-prove-it-with-tests]].
