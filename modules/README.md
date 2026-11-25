# Modules

The optional parts of the setup, one folder each. `MODULES` in `.env` says which are on, for example
`MODULES=domain,opencloud,ups,downloads`; `install.sh` and `obento` do the rest. `obento modules` lists them.

| Module | What it adds | Needs |
|---|---|---|
| `core` | Always on: Immich, Vaultwarden, Jellyfin, AdGuard Home, Scrutiny (`compose/docker-compose.yml`) | |
| `domain` | Your own web addresses (`photos.<APPS_DOMAIN>`, ...) through Traefik, and the portal at `<APPS_DOMAIN>` | `APPS_DOMAIN`, `DESEC_TOKEN` |
| `opencloud` | Files synced across devices (OpenCloud, a Google Drive replacement) | |
| `ups` | A UPS on USB: clean shutdown on low battery, power alerts, the portal's battery gauge | |
| `downloads` | Automatic TV and film downloads: Seerr, Sonarr, Radarr, Prowlarr, SABnzbd (Usenet), and subtitles with Bazarr | `domain` |
| `pi` | The pi coding agent on the server, with Node.js 22, using your own model server | `PI_URL`, `PI_MODEL` |

Without `MODULES` in `.env`, the setup from before modules applies: `opencloud`, `ups` and `pi`, plus `domain` and
`downloads` if the old `COMPOSE_PROFILES` setting names them.

**Turning a module on**: add it to `MODULES`, then `obento update && obento up`. Some have a setup step
afterwards (`sudo obento setup downloads`; see the RUNBOOK). **Off**: remove it, then `obento update && obento
up`: its apps are removed and its addresses and portal tiles go away. Its data stays where it was (for example
`/srv/sonarr`), so turning it back on picks up where it left off. What a module installed on the system itself
(NUT for `ups`, Node.js and pi for `pi`) stays until you remove it yourself.

## Addresses

With the `domain` module, every app gets `<name>.<APPS_DOMAIN>`. The names come from `HOSTS` in each module's
`module.conf` (`photos`, `files`, `requests`, ...) and can be changed in `.env` with `HOST_<NAME>`, for example
`HOST_REQUESTS=ask` for `ask.<APPS_DOMAIN>`. `install.sh` writes Traefik's routes and the portal's links from
them, and stops if two apps would get the same name. Changing a name means changing it on every device that
uses that app.

## What a module folder holds

Everything is optional except `module.conf`.

| File | What it is | Used by |
|---|---|---|
| `module.conf` | `DESCRIPTION`, `NEEDS` (other modules), `HOSTS` (`<name>:<app>:<localhost port>`; `@` is `APPS_DOMAIN` itself), `SERVE` (Tailscale serve `<https port>:<local port>` without `domain`), `PORTAL_LAYOUT` (`<group>:<columns>` for a new portal group) | `scripts/modules.sh` |
| `compose.yml` | The module's apps. Added after `compose/docker-compose.yml`, so paths are relative to `compose/` and `${...}` settings come from the same `.env` | `obento` |
| `install.sh` | Server setup for the module (folders, config files, system services), sourced by `install.sh` with its helpers (`install_conf`, `restart_if_stale`, `log`, `warn`, `host_name`, `module_on`); `MODULE_DIR` is the installed copy of the folder | `install.sh` |
| `portal.yaml` | Portal tiles, as Homepage groups. Groups with the same name are merged, in module order (core first). In links, `@<name>@` becomes the address name | `domain` |
| `setup.sh` | Connects the module's apps once they run (`sudo obento setup <module>`); safe to re-run | `obento setup` |

To add a module: make the folder, pick free ports (`ss -ltn` on the server; see AGENTS.md), add the module to
the table above and to `.env.example`, and check it with and without the module on (AGENTS.md "Verify before
you push").
