# BrightCare Clinic FAQ Chatbot

A basic conversational agent built with **Rasa Open Source 3.x** for the BSBI Certificate
Course *"Conversational AI and Chatbot Systems"* (group assignment).

The bot answers frequently asked questions for a fictional medical clinic:
opening hours, location and directions, contact details, services, appointment
booking and cancellation, insurance, preparation for diagnostic tests, and
specialist availability. It also detects emergency messages and immediately
redirects the user to the 112 emergency line, and discloses that it is a bot
when asked (`utter_iamabot`).

## Features

- **21 intents / ~530 training examples**, enriched with two public datasets
  (see *Data sources* below)
- **In-chat appointment booking** via a Rasa **form** (`appointment_form`) that
  collects specialty → preferred time → patient name → phone, with per-slot
  **validation in custom actions** (`actions/actions.py`) and a booking
  reference on submit
- **Digression handling**: the user can ask a question mid-form (e.g. opening
  hours) and the form resumes afterwards
- **Retrieval intents** (`chitchat/ask_name`, `tell_joke`, …) answered by the
  ResponseSelector
- **Human handoff**, **help**, affirm/deny, out-of-scope refusal (50 examples),
  confidence fallback, and a rule-enforced **emergency redirect to 112**
- **RegexEntityExtractor** for phone numbers + lookup tables for specialties
  and test types

## Project structure

| File | Purpose |
|---|---|
| `config.yml` | NLU pipeline (DIET + RegexEntityExtractor + fallback) and dialogue policies |
| `domain.yml` | Intents, entities, slots, form definition, and all bot responses |
| `data/nlu.yml` | Training examples for 21 intents, entity annotations, synonyms, regexes, lookups |
| `data/stories.yml` | Multi-turn training conversations incl. form digressions |
| `data/rules.yml` | Fixed behaviours (greeting, fallback, emergency, form activate/submit/cancel) |
| `actions/actions.py` | Form validation + appointment submission custom actions |
| `endpoints.yml` | Action server endpoint (localhost:5055) |
| `tests/test_stories.yml` | End-to-end test conversations for `rasa test` |
| `webchat/index.html` | Browser chat UI (REST channel) |

## Data sources

Parts of the NLU training data for generic intents (greet, goodbye, thanks,
bot_challenge, affirm, deny, chitchat/*, out_of_scope) were adapted from:

- **CLINC150 / OOS-eval** (Larson et al., 2019, EMNLP) — CC BY 3.0 —
  https://github.com/clinc/oos-eval
- **Rasa Sara demo** (`human_handoff` examples) — Apache 2.0 —
  https://github.com/RasaHQ/rasa-demo

Clinic-domain intents and all responses are hand-written; all clinic data is
fictional.

## Quick start (one command)

Everything below — Python check, virtualenv, Rasa install, training, all three
servers, browser — is automated:

```bash
# Windows
powershell -ExecutionPolicy Bypass -File run_local.ps1

# Linux / macOS / GitHub Codespaces
./run_local.sh
```

Stop with `run_local.ps1 -Stop` / `./run_local.sh stop`. Force retraining with
`-Retrain` / `retrain`. The scripts retrain automatically when files in
`data/`, `config.yml` or `domain.yml` are newer than the latest model.

## Manual setup

Rasa 3.x supports Python 3.8–3.10. In a fresh virtual environment:

```bash
pip3 install rasa
```

## Usage

```bash
rasa train            # train the NLU model and dialogue policies
rasa shell            # chat with the bot in the terminal
rasa shell nlu        # inspect intent/entity predictions for a message
rasa test             # run the test stories in tests/
rasa data validate    # check domain/data consistency
```

## Web chat UI (dev)

`webchat/index.html` is a dependency-free chat widget that talks to the Rasa REST
channel. To run the full dev stack:

```bash
# terminal 1 — action server (form validation + booking submit)
rasa run actions --port 5055

# terminal 2 — Rasa REST API with CORS open for the local page
rasa run --enable-api --cors "*" --port 5005

# terminal 3 — static server for the UI
python -m http.server 8088 --directory webchat
```

Then open <http://localhost:8088>. The widget shows connection status,
quick-reply buttons for common questions, and a typing indicator; each browser
tab gets its own `sender` id, so conversations don't mix.

## Example conversation

```
Your input -> hi
  Hello! Welcome to BrightCare Clinic. ...
Your input -> can I eat before giving blood?
  For a routine blood test, please fast for 8–12 hours beforehand ...
Your input -> and when is the lab open?
  ... The blood collection room works Monday–Saturday 08:00–11:00.
Your input -> thanks, bye
  Goodbye! Take care, and see you at BrightCare Clinic.
```

## Deployment (free options)

**GitHub Codespaces** (this repo is pre-configured via `.devcontainer/`):
1. Code → Codespaces → *Create codespace on main* — Rasa installs and the model
   trains automatically (~5 min).
2. In the terminal: `rasa run actions --port 5055 &` then
   `rasa run --enable-api --cors "*" --port 5005`.
3. *Ports* tab → port 5005 → **Port visibility → Public** → copy the URL.

**GitHub Pages** (chat UI): Settings → Pages → deploy from branch → `main`,
folder `/docs`. Then open:

```
https://<user>.github.io/clinic-chatbot/?rasa=<public Rasa URL>
```

The `?rasa=` query parameter points the chat at any Rasa server; without it,
the UI targets `http://localhost:5005` for local development.

**Docker** (any container host, incl. Hugging Face Spaces):
`Dockerfile` trains the model at build time and serves the API on port 7860.

**Local + tunnel** (instant public demo):
`cloudflared tunnel --url http://localhost:5005` gives a public HTTPS URL
for a bot running on your machine.

## Notes

- The FallbackClassifier threshold is 0.6: low-confidence messages get a polite
  "please rephrase" reply instead of a wrong answer.
- Responses use Rasa response conditions to tailor answers when the
  `test_type` / `specialty` slot is filled.
- All clinic data (address, phone numbers, doctors) is fictional.
