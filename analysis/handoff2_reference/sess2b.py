import sys; sys.path.insert(0,'/home/claude')
import numpy as np, pandas as pd, pickle
from scipy.signal import butter, filtfilt
from scipy.ndimage import gaussian_filter1d as gf
src=open('dtw.py').read().split('def all_bounds')[0]; exec(src)   # dtw_closed, features
w,st,sc,laps=pickle.load(open('sess2.pkl','rb'))
st_,res_,T,ds=pickle.load(open('dtw.pkl','rb')); tr=np.load('track.npz'); vT=tr['v']; wzT=tr['wz']
F=features(w); sig=w.wz_f.values; fs=100
rm=np.array([l['lapMs']/1000 for l in laps]); lapno=[l['lapNumber'] for l in laps]
# lap windows: start from IMU, length from RaceMann
starts=list(st); n=len(starts)
wins=[(starts[i], starts[i]+int(round(rm[i]*100))) for i in range(n)]
cuts_s=[2.76,8.38,15.82,19.42,24.98,28.78]
wzT100=np.interp(np.arange(len(wzT)*2)/2,np.arange(len(wzT)),wzT)
R=[]; paths=[]; B=[]
for i,(a,b) in enumerate(wins):
    if b>len(sig): break
    Bf=F[a:b:ds]; out=dtw_closed(T,Bf,band=100); path=out[0] if isinstance(out,tuple) else out
    p=np.array(path); paths.append(p)
    # residual
    wz_w=np.interp(p[:,0],np.arange(len(wzT)),wzT); resid=np.sqrt(np.mean((Bf[p[:,1],0]*1.2-wz_w)**2))
    # sector cuts
    cuts=[a]
    for c in cuts_s:
        ci=int(round(c*50)); j=p[np.argmax(p[:,0]>=ci),1]*ds+a
        W=200; best=None
        for s in range(-60,61):
            e=j+s
            if e-W<0 or e+W>len(sig): continue
            r=np.corrcoef(sig[e-W:e+W],wzT100[max(0,ci*2-W):ci*2+W])[0,1] if ci*2-W>=0 else 0
            if best is None or r>best[0]: best=(r,e)
        cuts.append(best[1])
    cuts.append(b); B.append(cuts)
    secs=np.diff(cuts)/100
    R.append(dict(lap=lapno[i],t=rm[i],resid=resid,ncc=sc[i],**{f'S{k+1}':secs[k] for k in range(7)}))
R=pd.DataFrame(R); pd.set_option('display.width',200); print(R.round(2).to_string())
pickle.dump((R,paths,B,wins),open('sess2_laps.pkl','wb'))
