# Protocol and behaviour in detail

Developer documentation on what happens behind the features described under [Usage](../README.md#usage) in the README. Fernsprecher talks to the OXO's XML Web Services interface (SOAP over HTTPS/443), the same one PIMphony uses. The protocol code lives in `OxoKit`. To try out individual calls: `oxoctl` (see README, "Developer CLI").

## Session

The OXO allows only one session per extension. Logging in with Fernsprecher ends e.g. PIMphony or `oxoctl` on the same extension, and vice versa.

Fernsprecher gives up the session and shows "Session lost" when

- the PBX reports a takeover,
- it loses the session again shortly after logging in, or
- it loses the session while the event stream is not running.

This way it does not take turns with the other program and does not silently take the extension back. Only "Reconnect" logs in again.

## Event stream

The app keeps the PBX's event stream open. When a call ends, it reloads the call log and counters right away. If the stream breaks, it reconnects, first after 5 s, then with increasing intervals up to 60 s.

## Sleep

After waking up, the app logs in again. If the PBX is unreachable, it retries, first after 30 s, then with increasing intervals up to 2 min.

## Missed calls

In addition to the event stream, the app polls `getNbUnansweredCall` every 30 s. When the menu is opened, it marks the missed calls among the loaded entries as seen (`modifyCallLog`), as PIMphony does: the newest 50, plus older pages once the user loads them. This also lowers the counter on the phone.

## Forwarding

**Reading:** The state is read on login, when the menu is opened, when the PBX reports a change (`e_phoneStaticState`) and every 30 s (`getStaticState`). Forwarding on no answer as set by PIMphony (dynamic routing) is not part of that state and changes without a notification from the PBX. The app reads it separately (`getDynamicRouting`), so it only sees it when the menu is opened or after 30 s at most.

**Setting:** as in PIMphony, via `XmlPhone setForwardState`. The R63 accepts `activateForward` but does not carry it out. The PBX replies without a status and silently discards a target it does not allow. The app therefore reads the state again after setting it; if it differs, it reports "The PBX did not accept the forward to …".

**Cancelling:** "Off" cancels immediate forwarding and dynamic routing (`cancelDynamicRouting`).

## Dialling and numbers

Calls are placed through the extension's phone (`makeCall`). The PBX reports external numbers without the trunk prefix (`0123…`, local `55555`). When dialling from the call log or phone book, the app therefore adds the trunk prefix, as PIMphony does, to every number with 5 or more digits; internal numbers have at most 4. Typed numbers (including forwarding targets) go to the PBX unchanged, as on a desk phone.

Custom names in the address book store the number without the trunk prefix, as the PBX reports it. "Copy number" returns this form too.
