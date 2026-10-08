# How it works

## How DBD picks a region

Dead by Daylight's matchmaking runs on AWS GameLift. Before it queues you, the game measures its latency to every
region it supports and sends all the results to BHVR's servers, which place you.

The game measures by sending UDP pings to each region's GameLift ping beacon, `gamelift-ping.<region>.api.aws`. It
looks each name up through Windows on every ping. (Older builds measured over HTTPS to `gamelift.<region>.amazonaws.com`
through the engine's libcurl, which keeps its own 60-second DNS cache. The tool still handles that mode by waiting the
cache out.)

## Steering

The tool writes a block into Windows' `hosts` file that points every region's endpoints, except the picked region's, at
`0.0.0.0` and `::`. Those lookups then give the game nothing it can ping, so those regions count as unreachable and only
the pick has a real latency. Everything outside the block stays byte for byte, and a DNS flush makes Windows use the
block at once.

If no region is reachable, or the pick doesn't answer its pings, every region reports the failure value. BHVR's server
then picks the region itself, usually not yours. The tool warns about that case.

## Making DBD measure again without a restart

The game measures at launch, and again when it reloads after losing its connection, but only if at least 600 s have
passed since its last completed measurement (BHVR can change that number remotely). A connection loss also resets the
stored results, so the next measurement really happens.

**Switch (no restart):**

1. Writes the steering and flushes DNS.
2. Waits until DBD's 10-minute window is open and DBD isn't connected to a lobby, match or end game chat. (A cut there
   doesn't bring up the connection error, so there's no reset.)
3. Cuts DBD's TCP connections (`SetTcpEntry` / delete TCB) and keeps cutting new connections to BHVR's backend until the
   game shows its connection error.
4. You click OK and press a key; the game reloads on its main loading screen and re-measures, with the steering in
   place.

**The clock option** skips the 10-minute wait. The game's rule compares the PC clock with the time of its last
measurement, so the tool moves the clock ahead just far enough right before the cut. It puts the clock back the moment
the game's first measurement lookup arrives (seen through ETW, timed with the PC's performance counter), before the game
records the time of its new measurement. The log says whether the clock was back before the game's first ping reply.

## Watching

The tool runs an ETW (Event Tracing for Windows) session with two providers:

- **DNS-Client:** which names the game looks up and what they resolve to. This is how the tool sees a measurement start,
  which regions answered, and when to put the clock back.
- **Kernel-Network:** the game's UDP traffic. This shows the ping replies, whether you're in a lobby or match, and the
  game server's address. The address's region comes from AWS's published `ip-ranges.json`. Some game-server addresses
  are listed there only as `GLOBAL` (no region, no reverse DNS name, no ping reply); the matchmaker still placed the
  server in a region the game could reach, so with steering that's the steered region.

A self-test every minute checks that Windows still delivers both kinds of events.

## Other stores

Steering, the cut, the clock option and the checks work by process, so they work with the Steam, Epic Games and
Xbox / Game Pass versions alike. Switch + Start/Restart starts the game the store's own way:

- **Steam:** `steam://rungameid/381210`.
- **Epic Games:** the launcher link built from the installed game's manifest.
- **Xbox / Game Pass:** the app's Start-menu entry.

All three start the game as your normal Windows user, never with the tool's admin rights.

Switch + Restart closes the game, EasyAntiCheat and DBD's launcher (`DeadByDaylight.exe`). The launcher matters: if
it's still open, say with an EasyAntiCheat error on screen, the store thinks DBD is running and ignores the new start.

If DBD isn't running, Switch + Start goes through whichever store DBD last ran from while the tool was open. Until the
tool has seen DBD run, it picks Steam if DBD is installed there, otherwise Epic or the Xbox app.

I've tried Steam and Epic with the real games. I don't have the Game Pass version, so the Xbox path is only covered by
the automated tests. Everything above about how DBD measures was worked out on the Steam version. Epic and Xbox run the
same game, so it should behave the same, but I haven't checked.
