# Libfx provider authorization is credential-led

Native libfx accepts one tagged provider authorization or an ordered list, with
the first entry selecting the initial provider and later switching limited to
that list. Codex sessions come only from an explicit optimistic host store or
an explicit `fxProfileSession()` opt-in, because an ordinary library home must
never grant ambient ChatGPT credential access. Browser and direct WebAssembly
libfx remain Gateway-only, and native libfx carries Gateway and Codex without
Grok.

The first accepted Codex credential pins the runtime to that ChatGPT account.
Every later store load validates the account before OAuth refresh or write-back.
Store timeouts fail the native operation immediately, but an abort-ignoring
host promise retains only its operation-owned copy until settlement. The timed
out runtime closes so a never-settling promise cannot strand a later request.
The ordinary libfx `home` also owns profile usage state; ambient `HOME` is not
consulted when an explicit library home is present.
