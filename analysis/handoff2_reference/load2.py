import numpy as np, pandas as pd
from scipy.spatial.transform import Rotation as R
def load_bin(f, conj=False):
    dt=np.dtype([('t','<i8'),('v','<f8',(10,))]); a=np.fromfile(f,dtype=dt)
    t=a['t'].astype(float); v=a['v']
    t=t/1e3 if t[0]<1e13 else t/1e9
    d=pd.DataFrame(v,columns=['accel_x_g','accel_y_g','accel_z_g','gyro_x_rads','gyro_y_rads','gyro_z_rads','quat_w','quat_x','quat_y','quat_z']); d['t']=t
    rot=R.from_quat(d[['quat_x','quat_y','quat_z','quat_w']].values)
    if conj: rot=rot.inv()
    d[['wx','wy','wz']]=rot.apply(d[['gyro_x_rads','gyro_y_rads','gyro_z_rads']].values)
    d[['ax','ay','az']]=rot.apply(d[['accel_x_g','accel_y_g','accel_z_g']].values)
    d['yaw']=np.unwrap(rot.as_euler('ZYX')[:,0])
    return d
