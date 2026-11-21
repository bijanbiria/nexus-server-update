# Security Policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems (for example a way
to bypass GPG checks, command injection through repo files, or unsafe file
handling as root).

Use GitHub's private reporting instead: **Security -> Report a vulnerability**
on this repository. You will get an answer within 7 days.

## Scope notes

- The optional password gate is an operator access control, not a secret
  store; the salted hash is readable by anyone who can read the script.
- `/etc/server_update.conf` is sourced as root and is only used when it is
  owned by root and not group/world writable.
