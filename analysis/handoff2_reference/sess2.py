import sys; sys.path.insert(0,'/home/claude')
import numpy as np, pandas as pd, json, pickle
from load2 import load_bin
from scipy.signal import butter, filtfilt, find_peaks
from align import ncc
D='data2/raw/2026-10-09T03-59-26_8AD223E8/'
d=load_bin(D+'watch_imu.bin'); fs=100
tu=np.arange(d.t.values[0],d.t.values[-1],0.01); w=pd.DataFrame({'t':tu})
for c in ['wz','ax','ay','az','yaw','wx','wy']: w[c]=np.interp(tu,d.t.values,d[c].values)
b,a=butter(2,1.5/(fs/2)); w['wz_f']=filtfilt(b,a,w.wz); w['ah_f']=filtfilt(b,a,np.hypot(w.ax,w.ay))
tmpl=np.load('tmpl.npy'); sig=w.wz_f.values
c=ncc(sig,tmpl); pk,_=find_peaks(c,distance=2800,height=0.5)
print('peaks',len(pk),'scores',np.round(c[pk],2))
# refine with tail+head template
pre=post=500; win=np.concatenate([tmpl[-pre:],tmpl[:post]]); st=[]
for p in pk:
    cand=[(np.corrcoef(sig[p+s-pre:p+s+post],win)[0,1],p+s) for s in range(-200,201) if p+s-pre>=0 and p+s+post<=len(sig)]
    st.append(max(cand)[1] if cand else p)
st=np.array(st); dur=np.diff(st)/100
print('IMU lap durations',np.round(dur,2))
# timing
t=json.load(open(D+'timing.json')); laps=json.loads(t['laps']) if isinstance(t['laps'],str) else t['laps']
laps=[l for l in laps if l['lapMs']<60000]
rm=np.array([l['lapMs']/1000 for l in laps]); print('RaceMann',np.round(rm,2))
# match sequences: find offset k such that dur[i] ~ rm[i+k]
best=None
for k in range(-5,6):
    n=min(len(dur),len(rm)-k) if k>=0 else min(len(dur)+k,len(rm))
    a_=dur[max(0,-k):max(0,-k)+n]; b_=rm[max(0,k):max(0,k)+n]
    e=np.abs(a_-b_); 
    if best is None or np.median(e)<best[1]: best=(k,np.median(e),n)
print('match offset',best)
pickle.dump((w,st,c[pk],laps),open('sess2.pkl','wb'))
