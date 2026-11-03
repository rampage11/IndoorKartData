import sys; sys.path.insert(0,'/home/claude')
import numpy as np, pandas as pd, pickle
from scipy.signal import butter, filtfilt
from scipy.ndimage import gaussian_filter1d as gf, label
fs=100
def add_frame(w, seg):
    b,a=butter(2,1.5/(fs/2)); axf=filtfilt(b,a,w.ax); ayf=filtfilt(b,a,w.ay); wz=w.wz_f.values; yaw=w.yaw.values; best=None
    for th in np.radians(np.arange(0,360,2)):
        psi=yaw+th; alat=-axf*np.sin(psi)+ayf*np.cos(psi); c=np.corrcoef(alat[seg],wz[seg])[0,1]
        if best is None or c>best[1]: best=(th,c)
    th=best[0]; psi=yaw+th; w['alat']=-axf*np.sin(psi)+ayf*np.cos(psi); w['along']=axf*np.cos(psi)+ayf*np.sin(psi)
    # HF band 2-8 Hz on raw wz
    b,a=butter(2,[2/(fs/2),8/(fs/2)],btype='band'); w['hf']=filtfilt(b,a,w.wz)**2
    return w, best
CORN={'T1':(0.64,2.64),'T2':(2.84,4.88),'T3':(6.10,7.34),'T4':(8.54,10.54),'T5':(13.72,15.36),'T6':(15.98,18.64),
      'T7':(19.62,22.26),'T8':(23.02,24.84),'T9':(25.08,28.52),'T10':(28.92,30.54),'T11':(31.68,33.16)}
def lap_metrics(w, a, b, path, ds=2):
    p=np.array(path); tj=p[:,1]*ds; ti=p[:,0]   # lap idx (rel) -> template idx (50Hz)
    def lap_idx(tT):  # template time -> absolute lap index
        return a+int(np.interp(tT*50, ti, tj))
    wz=w.wz_f.values; alat=w.alat.values; along=gf(w.along.values,8); hf=w.hf.values
    v=np.abs(alat)*9.81/np.maximum(np.abs(wz),0.3)
    out={}
    for name,(t0,t1) in CORN.items():
        i0,i1=lap_idx(t0),lap_idx(t1); i0b=max(a,i0-150)   # 1.5 s before entry for braking
        seg=slice(i0,i1); ap=i0+np.argmax(np.abs(wz[seg]))
        m=dict(vmin=v[seg][np.abs(wz[seg])>1.0].min()*3.6 if (np.abs(wz[seg])>1.0).any() else np.nan,
               alat_pk=np.abs(alat[seg]).max(), wz_pk=np.abs(wz[seg]).max(), hf=hf[seg].mean(),
               amin=along[i0b:i1].min(), dur=(i1-i0)/100)
        br=along[i0b:i1]<-0.25
        m['brake_on']=((np.argmax(br)+i0b)-i0)/100 if br.any() else np.nan   # s relative to corner entry
        m['brake_len']=br.sum()/100
        # slip: excess yaw vs a_lat/v
        vv=gf(v,30); exc=np.abs(wz[seg])-np.abs(alat[seg])*9.81/np.maximum(vv[seg],3)
        m['slip']=float((gf(exc,6)>0.28).sum()/100)
        out[name]=m
    return out
