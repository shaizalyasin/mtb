# mtb

Official cBioPortal **6.4.4**, unmodified, with our Molecular Tumor Board
features injected as a separately served JavaScript bundle.

No fork. No patched frontend source. No rebuilt image. Upgrading cBioPortal is
meant to become "change the image tag and redeploy", and this repository is the
evidence that it can.

The features themselves live in the sibling repository
[`mtb-clinical-tools`](https://github.com/shaizalyasin/mtb-clinical-tools). This one is only the deployment:
the portal, its database, and the configuration that tells the portal where to
find our bundle.

## Running it

**Requirements:** Linux, or Windows with WSL2. Run everything from inside the
Linux filesystem. Docker Engine with Compose v2, and about 15 GB free disk.

Only this repository needs cloning; Docker builds the bundle straight from its
public GitHub repository.

```bash
git clone https://github.com/shaizalyasin/mtb.git
cd mtb
```

```bash
./init.sh                       # schema, seed database and a demo study (~65MB)
docker compose up -d --build    # first boot seeds the database, a few minutes
./import-study.sh               # cBioPortal will not render with zero studies
```

The first run takes roughly ten minutes, most of it pulling images and loading
the seed database. `import-study.sh` waits for the portal itself, so the three
commands can be run one after another. Later runs start in seconds.

To work on the bundle rather than just run it, clone
[`mtb-clinical-tools`](https://github.com/shaizalyasin/mtb-clinical-tools)
alongside this repository and set `MTB_TOOLS_CONTEXT=../mtb-clinical-tools` in
[`.env`](.env), so compose builds your checkout instead of GitHub.

Then open <http://localhost:9090>, pick a patient from the imported study, and
click the **MTB Demo** tab.

Both ports live in [`.env`](.env) as `CBIOPORTAL_PORT` and `MTB_TOOLS_PORT`. Change them there and re-run `./init.sh`, which regenerates `config/frontend.json` so the tab keeps pointing at the right place.

On Windows, Hyper-V reserves TCP ranges, and binding inside one fails with *forbidden by its access permissions* even though nothing is listening. `netsh interface ipv4 show excludedportrange protocol=tcp` lists them; pick ports outside those ranges.

Stopping and resetting:

```bash
docker compose down       # stop, keep the database
docker compose down -v    # stop and wipe it -- next start re-seeds and you
                          # will need ./import-study.sh again
```

## Verifying it

```bash
./verify.sh
```

Run it with the stack up and a study imported. It drives a real headless browser through every claim and prints a line each. No
local Node or browser needed; it runs in a container.

```
PASS  Custom tab appears in the Patient View tab bar
PASS  Bundle loaded cross-origin and mountCallbackName resolved off window
PASS  Mutation count shows a pending state while the store is fetching
PASS  Mutation count went pending -> real number, and matches the REST API
PASS  Study / patient / sample identifiers read from the live store
PASS  No duplicate content after switching tabs away and back 3x
PASS  Remounted tab still reads the store
PASS  No MTB-related console errors

8/8 checks passed
```

Two of those are built so they could actually fail, which is the point of having
them:

- The mutation count normally resolves faster than a test can observe, and a
  value copied once at mount time would look identical to a live one. So the run
  **holds the response back until after the tab has mounted**, then requires a
  loading state followed by the real number, in one continuous mount.
- The count is cross-checked against cBioPortal's REST API, so it is corroborated
  by something other than the store being tested.

The same suite runs in CI on every push, and can be pointed at any cBioPortal
image tag from the Actions tab, which is how an upgrade would be evaluated
before committing to it.

## How the injection works

`custom_tabs` is JavaScript injection into cBioPortal's own page, not an iframe:

1. The backend reads `config/frontend.json`, passed to it
   as `--frontend.config`, and serves it to its own frontend.
2. The frontend adds a tab, loads the bundle's CSS and JS, then calls the global
   named by `mountCallbackName`.
3. Because it runs in the portal's own document, the callback can read the live
   patient store and re-render as data arrives.

That config file is the entire installation. Everything else here is a stock
cBioPortal deployment.

## Layout

| Path | What it is |
| --- | --- |
| [`docker-compose.yml`](docker-compose.yml) | The portal, its database, session service, and a static server for the bundle |
| [`config/frontend.json.template`](config/frontend.json.template) | **The injection point**: the `custom_tabs` entry. `init.sh` renders it into `config/frontend.json` |
| [`init.sh`](init.sh) | Downloads the schema, seed database and demo study |
| [`verify.sh`](verify.sh), `verify.mjs` | The browser verification |
| [`auth/`](auth/) | Optional Keycloak/OpenResty overlay, see below |
| `data/`, `study/` | Downloaded content, not committed |

## The authentication overlay (optional)

Everything under [`auth/`](auth/) is a separate question from the one above, and
is not needed to see the demo. It answers whether a mounted tab can reach an
authenticated backend the way the real MTB and Follow-up tabs will need to.

```bash
docker compose -f docker-compose.yml -f auth/docker-compose.yml up -d --build
./auth/verify-auth.sh          # 11/11
```

It adds Keycloak, an OpenResty proxy with `lua-resty-openidc`, and a stand-in for
FhirSpark, all on one origin. Demo login is `mtbuser` / `mtbuser`.

If you change `CBIOPORTAL_PORT`, update `PUBLIC_URL` in [`.env`](.env) and the
URLs in [`auth/realm-export.json`](auth/realm-export.json) to match. Keycloak
validates redirect URIs against the exact origin, so a mismatch fails the login
rather than falling back.

What it establishes:

- **No token handling is needed.** The bundle sends no credential; the browser
  attaches the session cookie itself because the request is same-origin. The test
  asserts this negatively, by inspecting every request the page makes.
- **Login handling *is* needed.** An unauthenticated write returns 401 with a
  `loginUrl`; the bundle has to open that flow and retry. The current fork has no
  such handling, because its deployment runs with `LOGINREQUIRED=false`.

Not covered: real FhirSpark (this is a stand-in reproducing its auth behaviour,
not its data model), and study-level permissions, which need the portal's own
login wired to Keycloak.

## Adding studies

`init.sh` downloads one demo study. To add another, put its directory under
`study/` and import it:

```bash
./import-study.sh <study-id>
```

Import runs cBioPortal's own `metaImport.py` inside the portal container, so a
study that imports there imports here.

`study/` and `data/` are not committed.

## Things worth knowing before changing anything

- **Config injection is pure runtime.** No frontend build is involved, so the
  official image is used exactly as published.
- **The tab `id` is not free-form.** It becomes a URL path segment and is
  validated by cBioPortal's router. An unrecognised id makes clicking the tab
  blank the entire patient view. See the comment in `config/frontend.json`.
- **`config/` is mounted as a directory, not a file.** Editors replace files
  rather than rewriting them, and a single-file bind mount breaks when its inode
  changes.
- **`init.sh` derives the seed version from the image.** Bumping the image tag
  picks up the matching seed automatically.

The full list of what to re-check when the cBioPortal version changes is in
[`mtb-clinical-tools/CONTRACT.md`](https://github.com/shaizalyasin/mtb-clinical-tools/blob/main/CONTRACT.md).
