# Scrubbed public-feed fixtures

These fixtures preserve only the fields Worldloom needs to test normalization. The Wikimedia sample was manually stripped of the upstream `user`, `user_text`, `ip`, `title`, `comment`, `revision`, `server_url`, URI, and numeric edit-id fields before it was committed. Its remaining timestamps, language-family codes, edit types, and byte lengths are representative but synthetic.

The USGS sample keeps public feature ids, magnitudes, places, timestamps, and coordinates. The Open-Meteo sample omits requested coordinates because Worldloom supplies a fixed, reviewed anchor list separately.
