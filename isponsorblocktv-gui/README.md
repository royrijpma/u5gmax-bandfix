# iSponsorBlockTV GUI

Sidecar web-GUI naast de ongewijzigde `ghcr.io/dmunozv04/isponsorblocktv` image.

```
isponsorblocktv-gui/
├── docker-compose.yml
├── README.md
└── gui/
    ├── Dockerfile
    ├── requirements.txt
    ├── app.py
    └── templates/index.html
```

## Starten op de QNAP

1. Zet de map op de NAS, bijvoorbeeld `/Volume1/docker/isponsorblocktv-gui/`.
2. Zorg dat `/Volume1/docker/isponsorblocktv/data/config.json` bestaat (maak die eerst met de officiële setup als je dat nog niet deed).
3. Build en start via SSH:
   ```bash
   cd /Volume1/docker/isponsorblocktv-gui
   docker compose up -d --build
   ```
   Of in Portainer: Stacks → Add stack → Repository/Upload, en zorg dat `./gui` bij de stack staat (build werkt alleen met de bestanden naast de compose).
4. Open `http://<nas-ip>:8095`.

## Goed om te weten

- De GUI heeft `/var/run/docker.sock` en is dus feitelijk root op de NAS. Houd poort 8095 binnen je LAN en zet eventueel `GUI_PASSWORD` in de compose (gebruiker `admin`).
- Statistieken staan in `data/stats.json`; ze tellen alleen vanaf het moment dat de GUI draait.
- Bij "Opslaan" worden alleen `mute_ads`, `skip_ads` en `skip_categories` aangepast; een back-up staat in `config.json.bak`.
- Update: de GUI kopieert env, volumes, netwerk, restart-policy en labels van de bestaande container, en zet bij een mislukte start de oude image terug.
- De tv-status is gebaseerd op logregels met de apparaatnaam; de exacte logtekst van iSponsorBlockTV kan per versie verschillen, dus pas de regexen in `device_status()` aan als video-ID's niet verschijnen.
