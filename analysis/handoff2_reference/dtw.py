import sys; sys.path.insert(0,'/home/claude')
from bounds import *
from scipy.signal import butter, filtfilt
def dtw_open_end(A,B,band=150):
    # A: template (N,k), B: lap window (M,k); start fixed at 0, end free in B
    N,M=len(A),len(B); INF=1e18
    D=np.full((N+1,M+1),INF); D[0,0]=0
    for i in range(1,N+1):
        lo=max(1,i-band); hi=min(M,int(i*M/N)+band if False else i+band+ (M-N))
        cost=np.sum((B[lo-1:hi]-A[i-1])**2,axis=1)
        prev=D[i-1]
        row=D[i]
        # diag & up vectorized; left sequential
        cand=np.minimum(prev[lo-1:hi], prev[lo:hi+1])
        for j in range(lo,hi+1):
            v=cand[j-lo]
            if row[j-1]<v: v=row[j-1]
            row[j]=cost[j-lo]+v
    jend=np.argmin(D[N,1:])+1
    # backtrack
    i,j=N,jend; path=[(i-1,j-1)]
    while i>1 or j>1:
        opts=[(D[i-1,j-1],i-1,j-1),(D[i-1,j],i-1,j),(D[i,j-1],i,j-1)]
        _,i,j=min(opts); path.append((i-1,j-1))
    return path[::-1], jend
def features(w):
    fs=100; b,a=butter(2,1.5/(fs/2))
    ah=filtfilt(b,a,np.hypot(w.ax,w.ay))
    w['ah_f']=ah
    F=np.c_[w.wz_f/1.2, (ah-ah.mean())/ah.std()*0.5]
    return F
def dtw_closed(A,B,band=100):
    N,M=len(A),len(B); INF=1e18
    D=np.full((N+1,M+1),INF); D[0,0]=0
    for i in range(1,N+1):
        c=int(round(i*M/N)); lo=max(1,c-band); hi=min(M,c+band)
        cost=np.sum((B[lo-1:hi]-A[i-1])**2,axis=1)
        prev=D[i-1]; row=D[i]
        cand=np.minimum(prev[lo-1:hi], prev[lo:hi+1])
        for j in range(lo,hi+1):
            v=cand[j-lo]
            if row[j-1]<v: v=row[j-1]
            row[j]=cost[j-lo]+v
    i,j=N,M; path=[(i-1,j-1)]
    while i>1 or j>1:
        _,i,j=min((D[i-1,j-1],i-1,j-1),(D[i-1,j],i-1,j),(D[i,j-1],i,j-1)); path.append((i-1,j-1))
    return path[::-1]
def all_bounds():
    w,st,tmpl=watch_bounds(); sig=w.wz_f.values; pre=post=500
    win=np.concatenate([tmpl[-pre:],tmpl[:post]]); p=st[-1]+len(tmpl)
    cand=[(np.corrcoef(sig[p+s-pre:p+s+post],win)[0,1],p+s) for s in range(-200,201) if p+s+post<=len(sig)]
    st=np.r_[st,max(cand)[1]]
    return w,st,tmpl
