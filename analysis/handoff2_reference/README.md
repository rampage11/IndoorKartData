# katahub telemetry v2 — reference scripts (session 2026-10-09, kart 57)
Order: load2.py (imu_v1 bin -> world frame) -> sess2.py (lap starts by NCC vs tmpl.npy + tail/head refine, match RaceMann)
-> sess2b.py (DTW per lap vs template T from dtw.pkl, 7 sector cuts) -> corners.py/run_corners.py (theta, per-corner metrics)
-> brake2.py (per-kart brake threshold test) -> maps3.py (phase maps, hybrid dot placement) / maps2.py (delta map).
Track assets: tmpl.npy (wz template @100Hz, 33.17 s), track.npz (x,y,v,tt,wz @50Hz). Template features T live in dtw.pkl (not included; rebuild = features(track) ).
Corner windows (template seconds): see CORN in corners.py. Sector cuts: [2.76,8.38,15.82,19.42,24.98,28.78].
