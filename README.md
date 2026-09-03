![version](https://img.shields.io/badge/version-20%2B-E23089)
![platform](https://img.shields.io/static/v1?label=platform&message=mac-intel%20|%20mac-arm%20|%20win-64&color=blue)
[![license](https://img.shields.io/github/license/miyako/4d-plugin-arguments)](LICENSE)
![downloads](https://img.shields.io/github/downloads/miyako/4d-plugin-arguments/total)

# 4d-plugin-arguments

This plugin exposes the host process's own command-line arguments to 4D. On macOS it reads them via `NSProcessInfo.arguments`; on Windows it reads them via `GetCommandLineW`/`CommandLineToArgvW`. The result is a `Collection` of `Text` elements, one per argument, in the exact order the process received them.

---

## Summary

| Command | Returns | Purpose |
|---|---|---|
| [Get command line](#get-command-line) | Collection | Returns the process's command-line arguments as a collection of text |

**Platforms:** macOS \| Windows

---

## Requirements & platform notes

- No permissions, entitlements, or minimum OS version beyond what 4D itself already requires — both underlying APIs (`NSProcessInfo.arguments` on macOS, `GetCommandLineW`/`CommandLineToArgvW` on Windows) are long-standing, unrestricted system APIs.
- **Element 0 is the program path, not the first "real" argument.** On both platforms the first element of the returned collection is the invoked executable's path/name (standard `argv[0]` convention) — if you only want arguments the user actually supplied, skip index 0.
- The command takes **no parameters** and always returns a `Collection` — there is no optional/alternate form.
- Failure is **silent, not a 4D error**: if an individual argument can't be converted (macOS) or the OS-level parse fails outright (Windows), that argument is simply missing from — or the whole collection is empty in — the result. See [Error handling](#error-handling--troubleshooting) below.

---

## Get command line

### Syntax

```
Get command line -> Collection
```

| Parameter | Type | Description |
|---|---|---|
| Result | Collection | One `Text` element per command-line argument, in the order the process received them. Element 0 is the executable's own path/name. |

### Description

Returns the arguments the current process was launched with, as a `Collection` of `Text` values. There are no parameters.

**On macOS**, the plugin reads `[[NSProcessInfo processInfo] arguments]` and converts each `NSString` to a `Text` value inside a UTF-16 buffer sized exactly to that string's length. If a given argument can't be converted for some reason, it's dropped from the collection rather than raising an error — the collection can come back shorter than the actual argument count in that (rare) case.

**On Windows**, the plugin reads `GetCommandLineW()` and parses it with `CommandLineToArgvW`. If that parse fails (undocumented but possible under memory pressure), the command returns an **empty collection** rather than raising a 4D error.

Both platforms include the invoked program's own path as the first element, matching the conventional `argv[0]` behavior of native command-line parsing — this is not 4D-specific behavior, so don't assume element 0 is the first argument the user typed after the app name.

### Example

From the plugin's own test method (`TEST.4dm`):

```4d
$arguments:=Get command line
```

Iterating over the result and skipping the program path at index 0:

```4d
var $arguments : Collection
var $i : Integer

$arguments:=Get command line

For ($i; 1; $arguments.length-1)
	ALERT($arguments[$i])
End for
```

Checking how the process was launched, e.g. for a `--debug` flag:

```4d
var $arguments : Collection
var $debugMode : Boolean

$arguments:=Get command line
$debugMode:=$arguments.query("$1 = :1"; "--debug").length>0
```

---

## Error handling & troubleshooting

- **A shorter-than-expected collection on macOS does not mean an error occurred.** An argument that fails to convert is silently omitted rather than surfacing as a 4D error — if you need to detect this, compare the returned collection's length against your own expectation of argument count rather than relying on an exception.
- **An empty collection on Windows can mean the OS-level parse failed**, not that the process was launched with zero arguments (every process has at least its own path as `argv[0]`, so a *truly* empty result is itself a signal something went wrong upstream). No 4D error is raised in this case.
- **Don't treat index 0 as a user-supplied argument.** It's the executable's own path on both platforms — filter it out before interpreting the collection as "the arguments the user passed."
- **No live cross-platform divergence in argument content itself** — both platforms return the same logical set (program path + launch arguments); the only divergence is in the two silent-failure modes above.

---

## Quick reference

```4d
// Raw arguments, including the program's own path at index 0
$arguments:=Get command line

// Just the user-supplied arguments
$arguments:=(Get command line).slice(1)

// Look for a flag
If ((Get command line).query("$1 = :1"; "--verbose").length>0)
	// ...
End if
```
