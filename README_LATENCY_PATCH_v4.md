# Latency OSD patch v4  - advanced requirement 3 (DONE)

Project copy : this folder  (repo root)
Bit          : td_project/camera_to_dsi_display_lat.bit   (23:51:34)

## OSD (top right, cyan)
    CAR        mode label (unchanged)
    LAT3F      handshake-free frame latency = ( write_ptr - read_ptr ) & 3
    048MS      latency in ms = frames x 16 ms

Verified on hardware: LAT3F / 048MS  (3 x 16.5 ms = 49.5 ms)

## Final implementation
video_in.v
  + O_video_in_wp[1:0]   write pointer (read pointer already existed)
  no other change

design_top_wrapper.v
  + S_lat_f = (S_video_in_wp - S_video_out_rp) & 2'b11
  + localparam FRAME_MS = 16      // 1650 x 750 / 75.002 MHz = 16.50 ms
  + W_lat_ms = S_lat_f * FRAME_MS, saturate to 999
  + both values 2FF-synced into the 75 MHz pixel clock
  + I_lat_f / I_lat_ms to hdmi_mixer

hdmi_mixer.v
  + I_lat_f[1:0], I_lat_ms[9:0]
  + "LAT<n>F" at (1010, 74) and "<ddd>MS" at (1010, 104)
  + ms -> 3 BCD digits by repeated subtraction (no divider), once per vsync
  + F_digit() 4-bit -> ASCII, X-safe fallback '0'
  + defaults on every new register -> no latches

## Build result
  slices 20,552 (96.87 %), RAM 90, DSP 34
  setup WNS -2.414 ns (ethernet domain, pre-existing), hold WNS +0.020 ns

## Notes / dead ends (do not repeat)
  * tagging each DDR buffer with a timestamp did not produce a usable value
    (the tag array is likely mapped to RAM, read-back returned 0)
  * measuring the frame period inside the DDR clock domain gave 3 ms instead
    of 16.5 ms, so the DDR clock period assumption does not hold in this design
  * a 17-bit literal (66667) was truncated by TD; use constants < 8192 and
    split dividers into stages

## Verify with a stopwatch
  phone stopwatch in front of the camera, photograph monitor + phone together:
  the difference of the two readings is the glass-to-glass latency and should
  match <ddd>MS within one frame (16.5 ms).

## Revert
  flash the previous bitstream from your own archive
