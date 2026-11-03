import sys; sys.path.insert(0,'/home/claude')
from laps import *
from scipy.signal import find_peaks
def ncc(sig, tmpl):
    n=len(tmpl); tm=(tmpl-tmpl.mean())/tmpl.std()
    out=np.full(len(sig)-n,np.nan)
    cs=np.cumsum(np.insert(sig,0,0)); cs2=np.cumsum(np.insert(sig**2,0,0))
    num=np.correlate(sig,tm,'valid')[:len(out)]
    mu=(cs[n:]-cs[:-n])/n; var=(cs2[n:]-cs2[:-n])/n-mu**2
    out=num/(n*np.sqrt(np.maximum(var,1e-9)))[:len(num)]
    return out
def detect(w, rough, ch='wz_f', iters=3):
    sig=w[ch].values; t=w.t.values
    i0=np.searchsorted(t,rough[2]); i1=np.searchsorted(t,rough[3])
    tmpl=sig[i0:i1]
    for it in range(iters):
        c=ncc(sig,tmpl)
        pk,_=find_peaks(c,distance=int(28*100),height=0.5)
        # build mean template from full laps
        L=len(tmpl); segs=[sig[p:p+L] for p in pk if p+L<len(sig)]
        tmpl=np.mean(segs,axis=0)
    return pk, c[pk], tmpl
