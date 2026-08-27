# Start here

## One command

```
lab
```

Wait 6 seconds. A window opens: brand new clean Windows, your App Installer already running.

Test it. Install things. Break things. Make a mess - it does not matter.

Found a bug? Fix the code in VS Code **on your real PC**, then type `lab` again.
The window comes back clean, with your new code.

That is the whole loop.

## The one rule

**You never clean up.** No uninstalling, no undoing, no closing anything specially.

`lab` throws the old mess away *before* it starts. Leaving the VM filthy is the design.

## The only other commands

| When | Type |
|---|---|
| Something broke, you want to look before it is wiped | nothing - just look at the window |
| See the error the VM printed | `lablog` |
| Copy/paste into the VM (once per day) | `labsync -Background` |
| Use the nicer VM instead of the plain one | `labpro` |

## Two things people get wrong

- **`lab` runs YOUR code.** `lab -Mode Live` runs the *published* build from the server -
  only use that after `Publish-Release.ps1`, to check what actually shipped.
- **Fix code on your PC, never inside the VM.** Anything you type inside the VM is thrown
  away on the next `lab`.

Everything else is in `README.md`, and you do not need it yet.
