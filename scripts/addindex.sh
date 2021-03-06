#!/usr/bin/env bash

# Usage:
#
# $ addindex.sh MBTILES [SEARCH-FIELD]
#

MBTILES=$1
FIELD=$2

if [ -z "$MBTILES" ]; then
    echo "Usage: addindex.sh MBTILES [SEARCH-FIELD]"
    exit 1
fi

if [ ! -f $MBTILES ]; then
    echo "File '$MBTILES' does not exist."
    exit 1
fi

if [ -z "$FIELD" ]; then
    FIELD="search"
fi

INDEXED=`sqlite3 "$MBTILES" "SELECT '1' FROM sqlite_master WHERE name = 'carmen';"`
if [ -z $INDEXED ]; then
  ZOOM=`echo "SELECT MAX(zoom_level) FROM map;" | sqlite3 $MBTILES`;

  # Create search table. Inserts id, text, zxy into `carmen` table.
  echo "CREATE INDEX IF NOT EXISTS map_grid_id ON map (grid_id);" > carmen-index.sql
  echo "CREATE VIRTUAL TABLE carmen USING fts4(id,text,zxy,tokenize=simple);" >> carmen-index.sql
  echo "BEGIN TRANSACTION;" >> carmen-index.sql

  sqlite3 "$MBTILES" \
    "SELECT k.key_name, k.key_json, GROUP_CONCAT(zoom_level||'/'||tile_column ||'/'||tile_row,',') AS zxy FROM keymap k JOIN grid_key g ON k.key_name = g.key_name JOIN map m ON g.grid_id = m.grid_id WHERE m.zoom_level='$ZOOM' AND k.key_json LIKE '%\"$FIELD\":%' GROUP BY k.key_name;" \
    | sed "s/\([^|]*\)|.*\"$FIELD\":\"\([^\"]*\)\"[^|]*|\(.*\)/INSERT INTO carmen VALUES(\"\1\",\"\2\",\"\3\");/" \
    >> carmen-index.sql

  echo "COMMIT;" >> carmen-index.sql

  LINES=`cat carmen-index.sql | wc -l`
  if [ $LINES == 4 ]; then
    FIELDS=`sqlite3 "$MBTILES" "SELECT key_json FROM keymap LIMIT 1" | grep -o '"[^":,]*":' | grep -o '[^":]*' | sed "s/\(.*\)/  \1/"`
    echo "Usage: addindex.sh MBTILES [SEARCH-FIELD]"
    echo ""
    echo "Available fields:"
    echo "$FIELDS"
    rm carmen-index.sql
    exit 1
  fi

  echo "Indexing $MBTILES..."
  sqlite3 "$MBTILES" < carmen-index.sql
  rm carmen-index.sql

  # Support addition of ASCII transliterated search terms if iconv is present.
  if [ `which iconv` ]; then
    echo "BEGIN TRANSACTION;" > carmen-index.sql
    IFS=$'\n'
    sqlite3 "$MBTILES" \
      "SELECT rowid, text FROM carmen WHERE TRIM(LOWER(text),'0123456789abcdefghijklmnopqrstuvwxyz,.- ') <> ''" \
      | iconv -t ASCII//TRANSLIT -f UTF-8 \
      | grep -v "[,?\"\\]" \
      | sed "s/\([^|]*\)|\(.*\)/UPDATE carmen SET text = text||', '||\"\2\" WHERE rowid = \"\1\" AND text <> \"\2\";/" \
      >> carmen-index.sql
    echo "COMMIT;" >> carmen-index.sql
    sqlite3 "$MBTILES" < carmen-index.sql
    rm carmen-index.sql
  fi
else
  echo "$MBTILES is already indexed."
fi
