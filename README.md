# Codex App remote development

Use the macOS Codex app with a Linux machine over SSH.

This works whether the host is reachable over Tailscale, your LAN, a VPN, or any other network path.

![Codex Hosts menu](./image.png)

## Usage

```bash
git clone https://github.com/larstalian/codex-app-remote.git
cd codex-app-remote
```

```bash
./codex-remote.sh --ssh-host <user>@<host> --apply
```

This:

- checks SSH access
- makes sure plain SSH can run `codex app-server`
- writes `~/.codex/remote-ssh-v0.toml`

If the script says it cannot find `codex`, do this first:

```bash
ssh <user>@<host>
command -v codex
```

If that prints something like `/home/<user>/.npm-global/bin/codex`, add that directory near the top of `~/.bashrc`:

```bash
export PATH="$HOME/.npm-global/bin:$PATH"

# rest of your bashrc
...
```

Then back on your Mac:

```bash
ssh <user>@<host> 'codex app-server --help'
./codex-remote.sh --ssh-host <user>@<host> --apply
```

## Open It In Codex

1. **Restart** Codex.
2. In the Apple menu (see picture) Open `Codex > Hosts > (remote) ...`.
3. A separate remote window will open.
4. Tada!

## If You Cannot SSH To The Remote Computer Yet

Install [Tailscale](https://github.com/tailscale/tailscale) on the remote machine, bring it online, and enable Tailscale SSH:

```bash
sudo tailscale up --ssh
```

Then run this repo against the Tailscale hostname:

```bash
./codex-remote.sh --ssh-host <user>@<tailscale-hostname> --apply
```

## Troubleshooting

If Codex opens a local folder picker, you are still in the local window.

## License

MIT. See [LICENSE](/Users/talian/Documents/New%20project/LICENSE).
