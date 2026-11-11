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
Linux filesystem. Docker Engine with Compose v2, and about 8 GB free disk.

Only this repository needs cloning; Docker builds the bundle straight from its
public GitHub repository.

```bash
git clone https://github.com/shaizalyasin/mtb.git
cd mtb
```

```bash
./init.sh                       # schema, seed database and the demo studies
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

Both ports live in [`.env`](.env). Change them there and re-run `./init.sh`, which
regenerates `config/frontend.json` to match.

On Windows, binding can fail with *forbidden by its access permissions* because
Hyper-V reserves TCP ranges. List them with
`netsh interface ipv4 show excludedportrange protocol=tcp` and pick a port outside.

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

The reactivity check is built so it can fail: the run **holds the mutation
response back until after the tab has mounted**, so the tab must show a loading
state and update itself. A value copied at mount time would not. The count is
cross-checked against the REST API.

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

It establishes that the bundle needs no token handling, since the browser attaches
the session cookie on a same-origin request, but does need login handling: an
unauthenticated write returns 401 with a `loginUrl` to act on.

Not covered: real FhirSpark (this is a stand-in for its auth behaviour, not its
data model), and study-level permissions, which need the portal's own login wired
to Keycloak.

## The Prognosis tab (optional)

Everything under [`risk/`](risk/) adds a second tab that scores the open
patient with the survival model in
[`mtb-survival-model`](https://github.com/shaizalyasin/mtb-survival-model).
Like `auth/`, it is an overlay, because the base demo answers one question and
should stay runnable without anything not needed to answer it.

```bash
docker compose -f docker-compose.yml -f risk/docker-compose.yml up -d --build
```

Without the overlay the tab still appears and reports that the service is
unreachable, which is the intended behaviour rather than a blank panel.

The tab fetches the patient's data from cBioPortal **in the browser**, under
the signed-in user's own session, then posts it to the risk service. The
service is never given a study or sample id and has no route to the portal, so
it holds no credentials and cannot be used to read a patient the user is not
entitled to see. It is also stateless: no database, no request logging of
payloads, nothing written after startup.

One caveat about the demo study. The model needs MSK-IMPACT features (TMB, MSI
score, fraction of genome altered, discrete CNA), and `lgg_ucsf_2014` has
almost none of them, so the tab will correctly report most inputs as missing.
For a demo that exercises the model, set `DATAHUB_STUDY=msk_chord_2024` in
[`.env`](.env), re-run `./init.sh` and import it: same panel family as the
training cohort, 25,040 patients the model has never seen.

## Studies

A portal holds as many studies as you import and lists them all on its home
page. `DATAHUB_STUDY` in [`.env`](.env) is a space-separated **list**, and
`init.sh` downloads every entry while `import-study.sh` imports every entry:

```bash
./init.sh                                  # downloads all of them
./import-study.sh                          # imports all of them
./import-study.sh lgg_ucsf_2014            # or just the ones you name
```

The default list is deliberately two studies that behave differently, because
the contrast is the useful part:

| study | size | what the Prognosis tab does with it |
| --- | --- | --- |
| `lgg_ucsf_2014` | 0.7 MB | No MSI, no FGA, no CNA profile, so the tab reports most inputs as missing. Worth seeing: that is what an unsuitable study looks like, rather than a confident wrong answer. |
| `msk_chord_2024` | 45 MB, 25,040 patients | Same MSK-IMPACT panel family as the model's training cohort, patients it has never seen. The tab works properly. |

The second one takes a while to import. Drop it from the list if you only want
the base demo running quickly, and add it back when you want the Prognosis tab
to do something.

To add any other study, put its directory under `study/` or add its id to the
list and re-run `./init.sh`. Import runs cBioPortal's own `metaImport.py`
inside the portal container, so a study that imports there imports here. A
failure on one study does not abandon the others; the script reports which
ones failed and exits non-zero.

### Gene panels

A panel-sequenced study carries a gene panel matrix, and cBioPortal requires
each panel it names to already exist in the database. The seed database ships
none, so importing such a study otherwise dies partway through with:

```
java.lang.RuntimeException: Gene panel cannot be found in database: IMPACT468
```

[`import-gene-panels.sh`](import-gene-panels.sh) handles this and
`import-study.sh` calls it first, so normally there is nothing to do. It reads
which panels a study needs out of the study's own matrix rather than from a
hardcoded list, because the list is not guessable: `msk_chord_2024` uses five,
and their file names do not follow their ids (`IMPACT-HEME-400` lives in
`data_gene_panel_heme400.txt`).

The definitions come from the cBioPortal datahub, where they are stored with
git-lfs. A `raw.githubusercontent.com` request returns a 129-byte LFS pointer
rather than the file, so they are fetched from the media endpoint instead.
They land in `study/_gene_panels/`, which is not committed.

`verify.sh` takes a single study and defaults to the **first** entry in the
list, or to `VERIFY_STUDY_ID` if you set one.

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
