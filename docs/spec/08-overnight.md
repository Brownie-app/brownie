# 08 · Overnight (scheduler, wake, power)

The overnight run is the same pipeline as "Analyze now", triggered at a scheduled time (default
3:00 AM) with the lid possibly closed.

## Rules
- Runs only if: Brownie is open (menu-bar process alive), **on AC power**, the schedule is enabled,
  and no run is active. On battery ⇒ skipped, recorded as `skipped(onBattery)`, morning banner.
- If a night is missed and "catch up" is on, run as soon as the Mac is plugged in **and idle for 20
  minutes** during the day.
- Never before the user's first unlock after a reboot (Keychain and protected data are unavailable).
- Notification for cards is delivered at 7:30 AM local (user-adjustable, never earlier than 7 AM);
  if the run finishes later, deliver on completion.

## Physics (macOS)
- A userspace power assertion (`PreventUserIdleSystemSleep`) prevents *idle* sleep but **does not
  hold a closed lid** — closing the lid forces sleep; the Mac then self-wakes in short maintenance
  bursts, which is not a continuous run.
- A scheduled wake (`pmset schedule wake`) fires reliably and the already-running process resumes.
- Holding the Mac awake with the lid shut for the duration of a run requires **root**
  (`pmset disablesleep 1`), and must be released the moment the run ends — or if the app dies.
- GPU inference works with the lid shut.

## The wake helper (the only root code)
A tiny privileged helper (`SMAppService` daemon in a proper build; a launchd plist installed once with
an admin prompt in the SwiftPM build) exposing exactly:
`armWake(at)`, `cancelWakes()`, `beginAwake() → lease`, `heartbeat(lease)`, `endAwake(lease)`.

- **Deadman timer:** `beginAwake` starts a timer the app must feed every 60 s via `heartbeat`; if
  feeding stops (crash, force-quit), the helper itself runs `disablesleep 0`. The safety lives outside
  the app on purpose.
- The helper cancels its armed wake when the app's connection drops (quit/crash) — a Mac with Brownie
  closed never wakes on a stale schedule.
- Code-signing gate on the XPC connection: the helper accepts only a client signed with the same
  designated requirement as itself (works for Developer ID, dev, and ad-hoc builds alike).
- Resets `disablesleep 0` defensively on its own launch.
- Logs to `/Library/Logs/Brownie-wakehelper.log`; the app's scheduler logs to
  `~/Library/Logs/Brownie/scheduler.log` (flushed per line — the black box for an empty morning).

## Scheduler (`OvernightScheduler`, in-app)
```
loop: compute next fire (today/tomorrow at HH:MM local) → helper.armWake → sleep until then
at fire: check AC + enabled + not running → helper.beginAwake → run(.overnight) with heartbeat
         → helper.endAwake → helper.armWake(next)
on wake notification / app launch: if a fire was missed while asleep → catch-up rules
```
- Login item so the process exists at 3 AM; Settings shows if it's off.
- Health log (Settings → Overnight): last 7 nights with woke / read / kept / took / outcome.
- "Test wake tonight" arms a wake 2 minutes out and runs a tiny dry run, so the user can verify the
  helper on day one.

## Morning-after classification (`RunOutcome` → banner copy)
`ran(cards) | skipped(onBattery) | skipped(appClosed) | skipped(notUnlocked) | failed(reader) |
failed(brain(usageLimit | unauthorized | other)) | cancelled | partial(stage)` — each has one
honest sentence and a next step.
