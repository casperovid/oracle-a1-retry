#!/bin/bash
# Prøver å lage A1-instansen playlist-crawler i AD-1 fra eksisterende boot-volum.
# Hver kjøring går i en loop i ca. 5 t 45 min: sjekker alle tre AD-er hvert 30. sekund,
# prøver å lage instansen når AD-1 er ledig, og uansett hvert 10. minutt.
# Skriver aldri ut OCID-er, fordi loggene er offentlige.
set -u

VARIGHET=20700   # 5 t 45 min
SJEKK=30         # sekunder mellom sjekker
TVANG=600        # sekunder mellom tvungne forsøk
AD="dfwl:EU-FRANKFURT-1-AD-1"
SHAPE='[{"instanceShape":"VM.Standard.A1.Flex","instanceShapeConfig":{"ocpus":2,"memoryInGBs":12}}]'

if [ -z "${C:-}" ]; then
  echo "Secrets mangler ennå. Gjør ingenting."
  exit 0
fi
if ! oci os ns get >/dev/null 2>&1; then
  echo "Innlogging mot Oracle feilet. Sjekk secrets. Gjør ingenting."
  exit 1
fi

skjul() { sed -E 's/ocid1\.[A-Za-z0-9._-]+/ocid1.[skjult]/g'; }
tid() { date -u +%T; }

slaa_av() {
  gh workflow disable retry.yml --repo "$GITHUB_REPOSITORY" && echo "Jobben er slått av."
}

T=$(oci ons topic list --compartment-id "$C" --all \
  --query "data[?name=='playlist-crawler-varsel'].\"topic-id\" | [0]" --raw-output 2>/dev/null)

varsle() {
  if [ -n "$T" ] && [ "$T" != "null" ] && \
     oci ons message publish --topic-id "$T" --title "Oracle-crawler: $1" --body "$1" >/dev/null 2>&1; then
    echo "$(tid) E-post sendt: $1"
  else
    echo "$(tid) KUNNE IKKE SENDE E-POST: $1"
  fi
}

adstat() {
  oci compute compute-capacity-report create --compartment-id "$C" \
    --availability-domain "dfwl:EU-FRANKFURT-1-AD-$1" --shape-availabilities "$SHAPE" \
    --query 'data."shape-availabilities"[0]."availability-status"' --raw-output 2>&1 | tail -1
}

BV=$(oci bv boot-volume list --compartment-id "$C" --availability-domain "$AD" \
  --query "data[?contains(\"display-name\",'playlist-crawler') && \"lifecycle-state\"=='AVAILABLE'].id | [0]" \
  --raw-output 2>/dev/null)

if [ -z "$BV" ] || [ "$BV" = "null" ]; then
  INST=$(oci compute instance list --compartment-id "$C" --display-name playlist-crawler \
    --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | length(@)" \
    --raw-output 2>/dev/null)
  if [ -n "$INST" ] && [ "$INST" != "0" ] && [ "$INST" != "null" ]; then
    echo "Instansen playlist-crawler finnes allerede. Ingenting å gjøre."
  else
    varsle "Fant ikke ledig boot-volum, og ingen instans finnes. Jobben er slått av."
  fi
  slaa_av
  exit 0
fi

SUB=$(oci network subnet list --compartment-id "$C" \
  --query "data[?\"display-name\"=='subnet-20260921-0125'].id | [0]" --raw-output 2>/dev/null)
if [ -z "$SUB" ] || [ "$SUB" = "null" ]; then
  varsle "Fant ikke subnettet. Jobben er slått av."
  slaa_av
  exit 1
fi

SRC="{\"sourceType\":\"bootVolume\",\"bootVolumeId\":\"$BV\"}"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

START=$(date +%s)
LAST=0
FEIL=0

while [ $(( $(date +%s) - START )) -lt $VARIGHET ]; do
  NOW=$(date +%s)
  S1=$(adstat 1); S2=$(adstat 2); S3=$(adstat 3)
  echo "$(tid) AD-1: $S1 | AD-2: $S2 | AD-3: $S3" | skjul

  # Tåler enkeltstående feil i kapasitetssjekken, men gir opp etter 10 på rad.
  if ! [[ "$S1" =~ ^[A-Z_]+$ && "$S2" =~ ^[A-Z_]+$ && "$S3" =~ ^[A-Z_]+$ ]]; then
    FEIL=$((FEIL + 1))
    if [ $FEIL -ge 10 ]; then
      varsle "Kapasitetssjekken har feilet 10 ganger på rad (se GitHub Actions). Jobben er slått av."
      slaa_av
      exit 1
    fi
    sleep $SJEKK
    continue
  fi
  FEIL=0

  # Husk forrige status for AD-2 og AD-3, også mellom kjøringene.
  P2=$(grep '^AD-2=' status.txt 2>/dev/null | cut -d= -f2)
  P3=$(grep '^AD-3=' status.txt 2>/dev/null | cut -d= -f2)
  [ "$S2" = "AVAILABLE" ] && [ "$P2" != "AVAILABLE" ] && varsle "AD-2 har ledig plass"
  [ "$S3" = "AVAILABLE" ] && [ "$P3" != "AVAILABLE" ] && varsle "AD-3 har ledig plass"
  if [ "$S2" != "$P2" ] || [ "$S3" != "$P3" ]; then
    printf 'AD-2=%s\nAD-3=%s\n' "$S2" "$S3" > status.txt
    git add status.txt
    git commit -q -m "Status: AD-2=$S2 AD-3=$S3" && git push -q && echo "$(tid) status.txt oppdatert."
  fi

  if [ "$S1" != "AVAILABLE" ] && [ $((NOW - LAST)) -lt $TVANG ]; then
    sleep $SJEKK
    continue
  fi
  LAST=$NOW

  echo "$(tid) Prøver å lage instansen i AD-1 (rapport: $S1)"
  OUT=$(oci compute instance launch --compartment-id "$C" --availability-domain "$AD" \
    --display-name playlist-crawler --shape VM.Standard.A1.Flex \
    --shape-config '{"ocpus":2,"memoryInGBs":12}' --source-details "$SRC" \
    --subnet-id "$SUB" --assign-public-ip true 2>&1)

  if echo "$OUT" | grep -q '"lifecycle-state"'; then
    echo "$(tid) Instansen er laget."
    varsle "Instansen er laget! Se Compute > Instances > playlist-crawler for ny IP."
    slaa_av
    exit 0
  elif echo "$OUT" | grep -qi 'TooManyRequests'; then
    echo "$(tid) For mange forespørsler. Venter 60 s."
    sleep 60
  elif echo "$OUT" | grep -qi 'capacity'; then
    echo "$(tid) Ingen kapasitet ved forsøk."
    sleep $SJEKK
  else
    echo "$OUT" | tail -20 | skjul
    varsle "Annen feil ved oppretting (se GitHub Actions). Jobben er slått av."
    slaa_av
    exit 1
  fi
done

echo "$(tid) Kjøringen er ferdig. Neste kjøring tar over."
