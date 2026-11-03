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
def phase(al,alat):
    ph=np.full(len(al),3)  # cruise
    ph[al>0.20]=2; ph[(al<-0.08)&(al>=-0.25)&(np.abs(alat)<0.6)]=1; ph[al<-0.25]=0
    return ph
COL={0:'#d94b4b',1:'#e9a23b',2:'#3f9d5a',3:'#b9b9b9'}
def draw_phase(ax,L,title):
    ax.plot(x,y,color='#e5e5e5',lw=11,solid_capstyle='round',zorder=0)
    ph=phase(L['along'],L['alat']); m=L['m']
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
    ax.set_title(title+'\nтормоз %.0f%% · сброс %.0f%% · газ %.0f%% · качение %.0f%% · срывов %d'%(pr[0],pr[1],pr[2],pr[3],cnt),fontsize=10)
    ax.set_aspect('equal'); ax.axis('off')
fig,axs=plt.subplots(1,2,figsize=(14,7))
draw_phase(axs[0],L31,'5 окт · карт 72 · круг 31 · 32.751')
draw_phase(axs[1],L63,'9 окт · карт 57 · круг 63 · 33.160')
plt.tight_layout(); plt.savefig('maps_phase_31_63.png',dpi=130)
# delta map: time at each template index for both laps
def t_of_template(L):
    m=L['m']; k=np.arange(L['N'])/100
    o=np.argsort(m); return np.interp(np.arange(NT),m[o],k[o])
t63=t_of_template(L63); t31=t_of_template(L31)
d=t63-t31; d=d-d[0]; dd=gf(np.gradient(d),25)   # local loss rate per template sample
fig,ax=plt.subplots(figsize=(8,7))
ax.plot(x,y,color='#e5e5e5',lw=11,solid_capstyle='round',zorder=0)
pts=np.c_[x,y].reshape(-1,1,2); segs=np.concatenate([pts[:-1],pts[1:]],axis=1)
lc=LineCollection(segs,cmap='RdYlGn_r',norm=plt.Normalize(-0.004,0.004),lw=6); lc.set_array(dd[:-1]); ax.add_collection(lc)
for name,(t0,t1) in CORN.items():
    i0,i1=int(t0*50),int(t1*50); loss=d[i1]-d[max(i0-100,0)]
    i=int((t0+t1)/2*50); ax.annotate('%s %+.2f'%(name,loss),(x[i],y[i]),fontsize=8,ha='center',va='center',bbox=dict(boxstyle='round,pad=0.2',fc='white',ec='none',alpha=0.85),zorder=4)
ax.plot(x[0],y[0],'k|',ms=14,mew=2); ax.set_aspect('equal'); ax.axis('off')
ax.set_title('Круг 63 (карт 57) относительно круга 31 (карт 72): где теряется время\nкрасный — медленнее, зелёный — быстрее; число — Δ на входе+повороте, с',fontsize=10)
cb=plt.colorbar(lc,ax=ax,shrink=0.6); cb.set_label('потеря, с на метр шаблона')
plt.tight_layout(); plt.savefig('map_delta_63_vs_31.png',dpi=130)
print('total delta %.2f'%d[-1]); 
for name,(t0,t1) in CORN.items():
    i0,i1=int(t0*50),int(t1*50); print(name,'%+.2f'%(d[i1]-d[max(i0-100,0)]))
np.savez('L63.npz',**L63); np.savez('L31n.npz',**L31)
