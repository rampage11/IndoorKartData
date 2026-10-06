"""Полный summary первого стинта на карте 72.

Входы:
- timing.json из любой сессии с полным allPasses (берём 19-21-26)
- Watch IMU непрерывная запись 2026-10-05T19-13-41_2D5D4AAF/watch_imu.bin
- Карта трека + разметка из analysis/tracks/miks.*

Выходы:
- /tmp/stint1_summary.png — multi-panel: lap times, position, pulse, chaser gaps
- /tmp/stint1_trajectory.png — trajectory overlay с цветом круга
- /tmp/stint1_bestlap.gif — animation прохождения лучшего круга с зонами торможений
- /tmp/stint1_theoretical.png — теоретический лучший круг по сегментам IMU
"""
import json, sys
from pathlib import Path
sys.path.insert(0, '/Users/mike/Developer/indoorKartdata/analysis')
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.image import imread
from matplotlib.collections import LineCollection
from matplotlib.animation import FuncAnimation, PillowWriter
from karttelemetry import loader

ROOT = Path('/tmp/all_sessions/sessions')
TIMING = ROOT / '2026-10-05T19-21-26_35951FED/timing.json'
WATCH_IMU = ROOT / '2026-10-05T19-13-41_2D5D4AAF/watch_imu.bin'
TRACK_IMG = Path('/Users/mike/Developer/indoorKartdata/analysis/tracks/miks.jpeg')
TRACK_JSON = Path('/Users/mike/Developer/indoorKartdata/analysis/tracks/miks.track.json')


def load_our_passes():
    tj = json.loads(TIMING.read_text())
    our = [p for p in tj['allPasses'] if p.get('kartNumber') == '72']
    # Дедуп по lapNumber (сервер может прислать Comp несколько раз для одного круга)
    seen = {}
    for p in our:
        ln = p.get('lapNumber')
        if ln is None: continue
        if ln not in seen:
            seen[ln] = p
    return [seen[k] for k in sorted(seen)]


def quat_to_yaw(w, x, y, z):
    return np.arctan2(2*(w*z + x*y), 1 - 2*(y*y + z*z))


def load_watch_imu():
    w = np.fromfile(WATCH_IMU, dtype=loader.IMU_DTYPE)
    t = (w['ts_ns'].astype(np.int64) - w['ts_ns'][0]) / 1e9
    return w, t


# ----- 1. Summary -----
def plot_summary(laps):
    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    fig.suptitle('Карт 72 — первый стинт 2026-10-05 (22:00 MSK) — 36 кругов', fontsize=13)

    lap_nums = [p['lapNumber'] for p in laps]
    lap_ms = [p['lastLapMs'] for p in laps]
    positions = [p.get('position', 0) for p in laps]
    best_ms = min(x for x in lap_ms if x > 0)

    # Lap times
    ax = axes[0,0]
    colors = ['red' if ms == best_ms else 'C0' for ms in lap_ms]
    bars = ax.bar(lap_nums, [ms/1000 for ms in lap_ms], color=colors)
    ax.axhline(best_ms/1000, color='red', ls='--', alpha=0.5, label=f'Best: {best_ms/1000:.3f}s')
    ax.set_xlabel('круг №')
    ax.set_ylabel('время, с')
    ax.set_title('Lap times')
    ax.set_ylim(32, 36)
    ax.legend()
    ax.grid(True, alpha=0.3)

    # Position evolution
    ax = axes[0,1]
    ax.plot(lap_nums, positions, 'o-', lw=2, color='C2')
    ax.set_xlabel('круг №')
    ax.set_ylabel('позиция')
    ax.set_title('Эволюция позиции')
    ax.invert_yaxis()
    ax.set_yticks([1,2,3,4,5])
    ax.axhspan(0.5, 1.5, color='gold', alpha=0.3, label='лидер')
    ax.axhspan(1.5, 3.5, color='silver', alpha=0.2, label='подиум')
    ax.legend()
    ax.grid(True, alpha=0.3)

    # Пульс из heart_rate.bin (возьмём из того же watch session)
    try:
        hr_path = ROOT / '2026-10-05T19-13-41_2D5D4AAF/heart_rate.bin'
        hr = np.fromfile(hr_path, dtype=loader.HR_DTYPE)
        hr_t_sec = (hr['ts_ns'].astype(np.int64) - hr['ts_ns'][0]) / 1e9
        ax = axes[1,0]
        ax.plot(hr_t_sec, hr['bpm'], 'o-', color='C3', ms=4)
        ax.set_xlabel('t, с от начала watch-записи')
        ax.set_ylabel('BPM')
        ax.set_title(f'Пульс (ср {hr["bpm"].mean():.0f}, пик {hr["bpm"].max():.0f})')
        ax.grid(True, alpha=0.3)
    except Exception as e:
        axes[1,0].set_title(f'Пульс: ошибка {e}')

    # Chaser gaps
    ax = axes[1,1]
    gaps = [p.get('gapToLeaderMs') for p in laps]
    gaps_s = [g/1000 if g else None for g in gaps]
    ax.plot(lap_nums, [g if g else 0 for g in gaps_s], 's-', color='C4', ms=5)
    ax.set_xlabel('круг №')
    ax.set_ylabel('отрыв от лидера, с')
    ax.set_title('Отрыв от лидера (из RaceMann)')
    ax.axhline(0, color='k', ls='-', alpha=0.3)
    ax.grid(True, alpha=0.3)

    fig.tight_layout(rect=(0, 0, 1, 0.96))
    out = Path('/tmp/stint1_summary.png')
    fig.savefig(out, dpi=120)
    plt.close(fig)
    print(f'wrote {out}')


# ----- 2. Trajectory per lap -----
def plot_trajectory(laps, watch_imu, watch_t):
    """Строим трассу по yaw из Watch, разбиваем на круги по времени из laps."""
    # Watch recording начинается wall=19:13:41 UTC. First our-lap wall=19:01:39.
    # Нам нужны laps которые закончились ПОСЛЕ начала watch recording.
    import datetime as dt
    def parse(s): return dt.datetime.fromisoformat(s.replace('Z','+00:00'))

    watch_start_wall = parse('2026-10-05T19:13:41Z')  # approximate from filename
    # На самом деле Watch wall-time в ts_ns хранится как timeIntervalSince1970 от Date()
    # Для корректности возьмём первый HR timestamp чтобы определить wall-time 0
    hr = np.fromfile(ROOT / '2026-10-05T19-13-41_2D5D4AAF/heart_rate.bin', dtype=loader.HR_DTYPE)
    watch_start_wall_ns = int(hr['ts_ns'][0])
    # watch IMU ts_ns — в nанах от первого семпла; wall time i-th семпла:
    #   watch_start_wall_ns + (ts_ns[i] - ts_ns[0])

    laps_covered = []
    for p in laps:
        lap_end_wall = parse(p['wallTime'])
        lap_end_ns = int(lap_end_wall.timestamp() * 1e9)
        lap_start_ns = lap_end_ns - p['lastLapMs'] * 1_000_000
        # Пересекается ли с диапазоном Watch?
        watch_end_ns = watch_start_wall_ns + int(watch_t[-1] * 1e9)
        if lap_end_ns > watch_start_wall_ns and lap_start_ns < watch_end_ns:
            laps_covered.append((p, lap_start_ns, lap_end_ns))

    print(f'  кругов в покрытии Watch: {len(laps_covered)}')

    # Для каждого покрытого круга вычисляем yaw-based shape
    yaw = np.unwrap(quat_to_yaw(watch_imu['qw'], watch_imu['qx'], watch_imu['qy'], watch_imu['qz']))
    dt_arr = np.diff(watch_t, prepend=watch_t[0])
    speed = 11.0  # ~40 km/h, подгоним позже
    # Полная trajectory всей watch-записи
    dx_full = speed * np.cos(yaw) * dt_arr
    dy_full = speed * np.sin(yaw) * dt_arr
    x_full = np.cumsum(dx_full)
    y_full = np.cumsum(dy_full)

    # Загружаем карту и разметку
    img = imread(str(TRACK_IMG))
    track_data = json.loads(TRACK_JSON.read_text())
    img_h, img_w = img.shape[:2]

    fig, axes = plt.subplots(1, 2, figsize=(16, 10))

    # Слева: без карты, только траектории по кругам
    ax = axes[0]
    ax.set_title(f'Traj per lap (Watch IMU, {len(laps_covered)} кругов)')
    cmap = plt.get_cmap('viridis')
    best_lap_num = min(laps_covered, key=lambda x: x[0]['lastLapMs'])[0]['lapNumber']
    for i, (p, start_ns, end_ns) in enumerate(laps_covered):
        start_idx = int(np.searchsorted(watch_t, (start_ns - watch_start_wall_ns)/1e9))
        end_idx = int(np.searchsorted(watch_t, (end_ns - watch_start_wall_ns)/1e9))
        if end_idx <= start_idx + 1: continue
        xs = x_full[start_idx:end_idx] - x_full[start_idx]
        ys = y_full[start_idx:end_idx] - y_full[start_idx]
        color = 'red' if p['lapNumber'] == best_lap_num else cmap(i / len(laps_covered))
        lw = 2.5 if p['lapNumber'] == best_lap_num else 0.8
        alpha = 1.0 if p['lapNumber'] == best_lap_num else 0.6
        ax.plot(xs, ys, color=color, lw=lw, alpha=alpha,
                label=f"lap {p['lapNumber']}: {p['lastLapMs']/1000:.3f}s" if p['lapNumber']==best_lap_num else None)
    ax.axis('equal')
    ax.grid(True, alpha=0.3)
    ax.legend(loc='upper right')
    ax.set_xlabel('x, м')
    ax.set_ylabel('y, м')

    # Справа: карта трека + разметка
    ax = axes[1]
    ax.imshow(img, origin='upper')
    traj_xs = [p[0] for p in track_data['trajectory_px']]
    traj_ys = [p[1] for p in track_data['trajectory_px']]
    ax.plot(traj_xs + [traj_xs[0]], traj_ys + [traj_ys[0]], 'cyan', lw=2, alpha=0.6, label='размеченная racing line')
    sf = track_data.get('start_finish_px', [])
    if sf:
        ax.plot([p[0] for p in sf], [p[1] for p in sf], 'r-', lw=3, label='отсечка')
    ax.set_title(f'MIKS трасса (direction=ccw) — {track_data.get("track_name", "?")}')
    ax.set_xlim(0, img_w)
    ax.set_ylim(img_h, 0)
    ax.axis('off')
    ax.legend(loc='lower left')

    fig.suptitle('Первый стинт: траектории по кругам (yaw-based shape из Watch IMU)', fontsize=12)
    fig.tight_layout()
    out = Path('/tmp/stint1_trajectory.png')
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print(f'wrote {out}')

    return laps_covered, x_full, y_full, watch_start_wall_ns, yaw


# ----- 3. Theoretical best from IMU segments -----
def theoretical_best(laps_covered, watch_imu, watch_t, watch_start_wall_ns, yaw):
    """Для каждого круга делим на 20 равных сегментов по доле прогресса (0..1),
    считаем время на каждый сегмент; минимум по всем кругам → теоретический
    лучший круг = сумма best-сегмент-времен."""
    N_SEG = 20
    seg_times_per_lap = []
    for p, start_ns, end_ns in laps_covered:
        start_idx = int(np.searchsorted(watch_t, (start_ns - watch_start_wall_ns)/1e9))
        end_idx = int(np.searchsorted(watch_t, (end_ns - watch_start_wall_ns)/1e9))
        if end_idx <= start_idx + 10: continue
        # Простое равное деление по времени (не по дистанции, т.к. скорость не знаем)
        total_s = (end_ns - start_ns) / 1e9
        seg_s = total_s / N_SEG
        times = [seg_s] * N_SEG  # всё поровну если делить по времени
        # ЛУЧШЕ: делить по пройденному пути (approximate by yaw+constant speed)
        # для простоты сейчас по времени — реально для теор. лучшего нужно разделение по дистанции
        seg_times_per_lap.append((p['lapNumber'], p['lastLapMs']/1000, times))

    if not seg_times_per_lap:
        print("  нет данных для теоретического лучшего")
        return

    # Для простоты: теоретический лучший = minimum PER SEGMENT across laps, суммируем
    # Но если делим по времени — каждый сегмент = total_time/20, бессмысленно.
    # Делаем честнее: процент прогресса круга → время этого сегмента.
    # Для MVP: используем сам lap_time и считаем best / median / theoretical= sum of per-lap min-segment-time
    # где сегмент = куск круга 5% прогресса.

    # Fairer approach: resample каждый круг на 20 равных timestamp bin'ов,
    # сравниваем "сколько прошло времени в этом бине" ≠ полезно так как не знаем скорость.

    # Правильнее: сравнить, во сколько ушёл первые/последние 5%/10%/20% прогресса.
    # Для MVP: разбить каждый круг на N временных сегментов относительно его общего
    # времени, посмотреть минимум per segment-index (это грубая эвристика).
    all_lap_times = [t for _, t, _ in seg_times_per_lap]
    best_lap = min(all_lap_times)
    median_lap = float(np.median(all_lap_times))
    # Honest theoretical best: minimum lap time — because without sector data
    # from RaceMann мы не можем честно собрать composite.
    print(f"\n  === Теоретический лучший (из того что знаем) ===")
    print(f"  Best lap в стинте:         {best_lap:.3f} с (из {len(all_lap_times)} кругов)")
    print(f"  Медиана:                   {median_lap:.3f} с")
    print(f"  Среднее:                   {np.mean(all_lap_times):.3f} с")
    print(f"  σ (стабильность):          {np.std(all_lap_times)*1000:.0f} мс")
    print(f"  Разброс лучший — медиана:  {(median_lap - best_lap)*1000:.0f} мс")


# ----- 4. Animation of best lap -----
def animate_best_lap(laps_covered, watch_imu, watch_t, watch_start_wall_ns):
    """Анимация прохождения лучшего круга с зонами торможений/разгонов."""
    best = min(laps_covered, key=lambda x: x[0]['lastLapMs'])
    p, start_ns, end_ns = best
    print(f'\n  Animating best lap #{p["lapNumber"]}: {p["lastLapMs"]/1000:.3f}s')

    start_idx = int(np.searchsorted(watch_t, (start_ns - watch_start_wall_ns)/1e9))
    end_idx = int(np.searchsorted(watch_t, (end_ns - watch_start_wall_ns)/1e9))
    sub = watch_imu[start_idx:end_idx]
    t_rel = watch_t[start_idx:end_idx] - watch_t[start_idx]

    # Yaw-based trajectory
    yaw_sub = np.unwrap(quat_to_yaw(sub['qw'], sub['qx'], sub['qy'], sub['qz']))
    dt = np.diff(t_rel, prepend=t_rel[0])
    speed = 11.0
    x = np.cumsum(speed * np.cos(yaw_sub) * dt)
    y = np.cumsum(speed * np.sin(yaw_sub) * dt)

    # Longitudinal G proxy: userAccel magnitude
    g_horiz = np.sqrt(sub['ax']**2 + sub['ay']**2)
    # Smooth
    kernel = np.ones(10)/10
    g_horiz_smooth = np.convolve(g_horiz, kernel, mode='same')

    # Classify segments: braking vs acceleration
    # Будем смотреть yaw-rate (угл.скорость around Z) и |a_long|.
    # Для MVP: цвет линии = интенсивность |g_horiz| (красный больше = сильнее)
    #          зоны торможения: g_horiz > 0.5
    #          зоны разгона:    выход из поворота + малая горизонтальная G

    # Создаём fig
    fig, (ax_track, ax_g) = plt.subplots(2, 1, figsize=(10, 10),
                                          gridspec_kw={'height_ratios': [3, 1]})

    # TRACK
    ax_track.set_aspect('equal')
    ax_track.set_title(f"Best lap {p['lapNumber']}: {p['lastLapMs']/1000:.3f}s — анимация прохождения")
    margin = 10
    ax_track.set_xlim(x.min()-margin, x.max()+margin)
    ax_track.set_ylim(y.min()-margin, y.max()+margin)
    ax_track.grid(True, alpha=0.3)
    ax_track.set_xlabel('x, м (yaw-based приближение)')
    ax_track.set_ylabel('y, м')

    # Статично: цвет линии = |a_horiz| normalize
    norm = plt.Normalize(0, g_horiz.max())
    pts = np.array([x, y]).T.reshape(-1,1,2)
    segs = np.concatenate([pts[:-1], pts[1:]], axis=1)
    lc = LineCollection(segs, cmap='RdYlGn_r', norm=norm, alpha=0.3, lw=2)
    lc.set_array(g_horiz_smooth[:-1])
    ax_track.add_collection(lc)
    cbar = fig.colorbar(lc, ax=ax_track, shrink=0.7, label='|horizontal G|')

    # Моbile dot + растущая линия
    (line_so_far,) = ax_track.plot([], [], color='k', lw=2.5, alpha=0.9)
    dot = ax_track.scatter([], [], c=[], s=200, cmap='RdYlGn_r', norm=norm, edgecolors='k', zorder=5)
    text_t = ax_track.text(0.02, 0.98, '', transform=ax_track.transAxes, va='top', fontsize=11,
                           bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

    # G-forces timeline
    ax_g.plot(t_rel, g_horiz_smooth, color='k', lw=0.8)
    ax_g.fill_between(t_rel, 0, g_horiz_smooth, where=g_horiz_smooth>0.5,
                      color='red', alpha=0.4, label='|G|>0.5 (торможение/поворот)')
    ax_g.set_xlabel('t, с от начала круга')
    ax_g.set_ylabel('|G|')
    ax_g.grid(True, alpha=0.3)
    ax_g.legend(loc='upper right')
    ax_g.set_xlim(0, t_rel[-1])

    cursor_line = ax_g.axvline(0, color='r', lw=1.5)

    # Downsample animation (не нужно 100 Гц)
    step = 5  # ~20 FPS
    frames = range(0, len(x), step)

    def init():
        line_so_far.set_data([], [])
        dot.set_offsets(np.empty((0,2)))
        return line_so_far, dot, text_t, cursor_line

    def update(i):
        line_so_far.set_data(x[:i], y[:i])
        if i > 0:
            dot.set_offsets([[x[i-1], y[i-1]]])
            dot.set_array(np.array([g_horiz_smooth[i-1]]))
        cursor_line.set_xdata([t_rel[i-1] if i>0 else 0])
        text_t.set_text(f't = {t_rel[i-1] if i>0 else 0:.2f} с  |G| = {g_horiz_smooth[i-1] if i>0 else 0:.2f}')
        return line_so_far, dot, text_t, cursor_line

    anim = FuncAnimation(fig, update, frames=frames, init_func=init,
                         interval=50, blit=False)

    out = Path('/tmp/stint1_bestlap.gif')
    anim.save(str(out), writer=PillowWriter(fps=20))
    plt.close(fig)
    print(f'  wrote {out}')


def main():
    laps = load_our_passes()
    print(f'Loaded {len(laps)} laps for kart 72')

    plot_summary(laps)
    watch, wt = load_watch_imu()
    laps_covered, x_full, y_full, watch_start_wall_ns, yaw = plot_trajectory(laps, watch, wt)
    theoretical_best(laps_covered, watch, wt, watch_start_wall_ns, yaw)
    if laps_covered:
        animate_best_lap(laps_covered, watch, wt, watch_start_wall_ns)


if __name__ == '__main__':
    main()
