import sys; sys.path.insert(0,'/home/claude')
import numpy as np, pandas as pd, pickle
from scipy.ndimage import gaussian_filter1d as gf
from corners import CORN
def lapidx(path,ds=2):
    p=np.array(path); return lambda tT,a: a+int(np.interp(tT*50,p[:,0],p[:,1]*ds))
def scan(w,wins,paths,labels,c0,c1,margin):
    rows=[]
    for i,(a,b) in enumerate(wins):
        f=lapidx(paths[i]); al=gf(w.along.values,8); la=w.alat.values
        for name,(t0,t1) in CORN.items():
            i0=max(a,f(t0,a)-150); i1=f(t1,a)
            seg=slice(i0,i1); thr=-(c0+c1*np.abs(la[seg]))-margin
            br=(al[seg]<thr)&(al[seg]<-0.25)
            # also flag pure straight-line decel beyond -0.25 as brake (alat<0.4)
            rows.append(dict(lap=labels[i],corner=name,brake=br.sum()/100,amin=al[seg].min(),
                             excess=(al[seg]-thr).min()))
    return pd.DataFrame(rows)
w2=pickle.load(open('w2.pkl','rb')); R2,paths2,B2,wins2=pickle.load(open('sess2_laps.pkl','rb'))
wo=pickle.load(open('wo.pkl','rb')); st_,res_,T,ds=pickle.load(open('dtw.pkl','rb'))
wins_o=[(st_[n],st_[n]+np.array(p)[-1,1]*ds) for n,p in enumerate(res_)]
for c0,c1,mg in [(0.0,0.0,0.25),(0.12,0.25,0.10),(0.10,0.30,0.10)]:
    print('=== model c0=%.2f c1=%.2f margin=%.2f'%(c0,c1,mg))
    A=scan(w2,wins2[:len(paths2)],paths2,list(R2.lap),c0,c1,mg); A=A[~A.lap.isin([51])]
    O=scan(wo,wins_o,res_,list(range(23,37)),c0,c1,mg)
    t=pd.DataFrame({'new_frac_laps_braking':A.groupby('corner').brake.apply(lambda s:(s>0.1).mean()),'new_med_len':A.groupby('corner').brake.median(),
                    'old_frac':O.groupby('corner').brake.apply(lambda s:(s>0.1).mean()),'old_med_len':O.groupby('corner').brake.median()}).loc[list(CORN)]
    print(t.round(2).to_string())
