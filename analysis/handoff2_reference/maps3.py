import sys; sys.path.insert(0,'/home/claude')
import numpy as np, pandas as pd, pickle
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from scipy.ndimage import gaussian_filter1d as gf, label
from corners import CORN
tr=np.load('track.npz'); x,y,vT=tr['x'],tr['y'],tr['v']; NT=len(x)
w2=pickle.load(open('w2.pkl','rb')); R2,paths2,B2,wins2=pickle.load(open('sess2_laps.pkl','rb'))
wo=pickle.load(open('wo.pkl','rb')); st_,res_,T,ds=pickle.load(open('dtw.pkl','rb'))
def hybrid(path,wz,v,a,N):
    p=np.asarray(path); m0=np.interp(np.arange(N),p[:,1]*ds,p[:,0])
    zc=np.where(np.diff(np.sign(wz))!=0)[0]; zc=[z for z in zc if np.abs(wz[max(0,z-50):z+50]).max()>0.8]
    an=[0]
    for z in zc:
        if z-an[-1]>50 and z<N-51: an.append(int(z))
    an.append(N-1); s=np.cumsum(v)/100; m=np.empty(N)
    for a_,b_ in zip(an[:-1],an[1:]):
        fr=(s[a_:b_+1]-s[a_])/max(s[b_]-s[a_],1e-6); m[a_:b_+1]=m0[a_]+fr*(m0[b_]-m0[a_])
    return m
def lapdata(w,a,b,path):
    N=b-a; wz=w.wz_f.values[a:b]; alat=w.alat.values[a:b]; along=gf(w.along.values[a:b],8)
    v=np.abs(alat)*9.81/np.maximum(np.abs(wz),0.3); v=np.clip(v,3,20); v[np.abs(wz)<1.0]=np.nan
    idx=np.arange(N); v=np.interp(idx,idx[~np.isnan(v)],v[~np.isnan(v)]); v=gf(v,30)
    m=hybrid(path,wz,v,a,N)
    vv=gf(v,30); exc=gf(np.abs(wz)-np.abs(alat)*9.81/np.maximum(vv,3),6)
    return dict(wz=wz,alat=alat,along=along,v=v,m=m,exc=exc,N=N)
i63=list(R2.lap).index(63); a,b=wins2[i63]; L63=lapdata(w2,a,b,paths2[i63])
n31=31-23; a_=st_[n31]; b_=a_+np.array(res_[n31])[-1,1]*ds; L31=lapdata(wo,a_,b_,res_[n31])
def phase(al,alat,cut):
    ph=np.full(len(al),3)  # cruise
    ph[al>0.20]=2; ph[(al<-0.12)&(al>=cut)]=1; ph[al<cut]=0
    return ph
COL={0:'#d94b4b',1:'#e9a23b',2:'#3f9d5a',3:'#b9b9b9'}
def draw_phase(ax,L,title,cut):
    ax.plot(x,y,color='#e5e5e5',lw=11,solid_capstyle='round',zorder=0)
    ph=phase(L['along'],L['alat'],cut); m=L['m']
    for k in range(0,L['N']-1,4):
        i0=int(m[k])%NT; i1=int(m[min(k+4,L['N']-1)])%NT
        if i1<i0: continue
        ax.plot(x[i0:i1+1],y[i0:i1+1],color=COL[ph[k]],lw=6,solid_capstyle='round',zorder=1)
    lab,n=label(L['exc']>0.28); cnt=0
    for q in range(1,n+1):
        idx=np.where(lab==q)[0]
        if len(idx)>=8:
            k=idx[np.argmax(L['exc'][idx])]; i=int(m[k])%NT; ax.plot(x[i],y[i],'o',ms=9,mfc='none',mec='#3b3bb0',mew=2,zorder=3); cnt+=1
    for name,(t0,t1) in CORN.items():
        i=int((t0+t1)/2*50)%NT; ax.annotate(name,(x[i],y[i]),fontsize=8,color='#555',ha='center',va='center',
            xytext=(0,0),textcoords='offset points',bbox=dict(boxstyle='circle,pad=0.15',fc='white',ec='none',alpha=0.8),zorder=4)
    ax.plot(x[0],y[0],'k|',ms=14,mew=2,zorder=5)
    pr=np.bincount(ph,minlength=4)/len(ph)*100
    ax.set_title(title+'\nтормоз (< %.2f g) %.0f%% · сброс/лёгкий трейл %.0f%% · газ %.0f%% · ровно %.0f%% · срывов %d'%(-cut,pr[0],pr[1],pr[2],pr[3],cnt),fontsize=10)
    ax.set_aspect('equal'); ax.axis('off')
fig,axs=plt.subplots(1,2,figsize=(14,7))
draw_phase(axs[0],L31,'5 окт · карт 72 · круг 31 · 32.751',-0.47)
draw_phase(axs[1],L63,'9 окт · карт 57 · круг 63 · 33.160',-0.50)
plt.tight_layout(); plt.savefig('maps_phase_31_63_v2.png',dpi=130)
