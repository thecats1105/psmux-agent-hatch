# Forward a bell from a dedicated agent session to the user.
#
#   bell.ps1 <session-name>   bound to the alert-bell hook with #{session_name}
#
# tmux marks the origin window's bell flag; psmux offers no way to ring another
# pane, so the equivalent here is a status-line message on the client that
# launched the session.

param([string]$Session = '')

. "$PSScriptRoot/helpers.ps1"

$provider = Get-SessionProvider $Session
if (-not $provider) { exit 0 }

$origin = Get-AgentOrigin $Session
if (-not $origin -or -not $origin.Session) { exit 0 }
# Never forward onto another dedicated session (forwarding loop).
if (Get-SessionProvider $origin.Session) { exit 0 }

$message = "🔔 $($provider.Name) needs you ($Session)"
$parent = Get-AgentParent
if ($parent) { Invoke-Psmux display-message -c $parent $message | Out-Null }
else { Invoke-Psmux display-message $message | Out-Null }
exit 0
