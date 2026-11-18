# iSponsorBlockTV GUI

Sidecar-dashboard voor [iSponsorBlockTV](https://github.com/dmunozv04/iSponsorBlockTV). De officiële image blijft ongewijzigd.

## Mappen
```
isponsorblocktv-gui/
├── app.py
├── templates/index.html
├── requirements.txt
├── Dockerfile
├── docker-compose.yml
└── README.md
```

## Starten op de NAS
1. Zet deze map op de NAS (bv. `/Volume1/docker/isponsorblocktv-gui`).
2. Zorg dat `/Volume1/docker/isponsorblocktv/data/config.json` bestaat (je bestaande koppelingen).
3. Bouwen en starten:
   ```bash
   cd /Volume1/docker/isponsorblocktv-gui
   docker compose up -d --build
   ```
   In Portainer: Stacks → Add stack → Repository (nieuwe GitHub-repo) of Upload, met `docker-compose.yml`. Bij een web-editor-stack moet de image eerst lokaal gebouwd zijn (`docker build -t isponsorblocktv-gui:local .`).
4. Open `http://<nas-ip>:8095`.

## Let op
- De GUI heeft toegang tot de Docker socket (= root-rechten op de host). Stel poort 8095 niet bloot aan internet.
- De GUI maakt een back-up `config.json.bak` bij elke opslag en wijzigt alleen `mute_ads`, `skip_ads` en `skip_categories`.
- Tellers staan in `data/stats.json` en overleven herstarts en updates.
- TV-status en video-ID worden uit logregels afgeleid; pas de regexen in `app.py` aan als jouw logformaat afwijkt.
