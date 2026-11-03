import sys; sys.path.insert(0,'/home/claude')
from corners import *
# new session
w2,st,sc,laps=pickle.load(open('sess2.pkl','rb')); R2,paths2,B2,wins2=pickle.load(open('sess2_laps.pkl','rb'))
w2,th2=add_frame(w2,slice(st[1],st[-1])); print('new theta',np.degrees(th2[0]),th2[1])
rows=[]
for i,(a,b) in enumerate(wins2[:len(paths2)]):
    for c,m in lap_metrics(w2,a,b,paths2[i]).items(): rows.append(dict(sess='new',lap=R2.lap[i],t=R2.t[i],corner=c,**m))
# old
st_,res_,T,ds=pickle.load(open('dtw.pkl','rb')); wo=pd.read_pickle('w.pkl'); wo,tho=add_frame(wo,slice(st_[0],st_[-1])); print('old theta',np.degrees(tho[0]),tho[1])
rl=pd.read_csv('data/race_laps.csv'); k=rl[rl.kart_number==72].set_index('lap')
for n,p in enumerate(res_):
    a=st_[n]; b=a+np.array(p)[-1,1]*ds; lap=23+n
    for c,m in lap_metrics(wo,a,b,p).items(): rows.append(dict(sess='old',lap=lap,t=k.lap_time_s.get(lap,np.nan),corner=c,**m))
M=pd.DataFrame(rows); M.to_pickle('M2.pkl')
pickle.dump(w2,open('w2.pkl','wb')); pickle.dump(wo,open('wo.pkl','wb'))
