// NSR 8BP — deterministic physics + exact prediction + auto-play (C++ port of preview/engine.js).
// Same constants, same operation order => identical outcomes to the validated JS engine.
#pragma once
#include <vector>
#include <map>
#include <cmath>
#include <algorithm>

namespace nsr {

constexpr double W = 1000, H = 500, R = 13, POCKET = 24;
constexpr double DECEL = 140, CUSH = 0.85, BALL_REST = 0.96;
constexpr double DT = 1.0 / 240.0, MAXV = 1500, MAXT = 8;

struct Vec { double x, y; };
struct Ball { int id; double x, y, vx, vy; bool on; };
struct Shot { double ang, power, spin; };

static const Vec POCKETS[6] = { {0,0},{W/2,-6},{W,0},{0,H},{W/2,H+6},{W,H} };

// 0xRRGGBB per ball id (used to color the prediction line + stop circle)
static const unsigned COLORS[16] = {
  0xf2f4f8,0xf6c500,0x1f6fd6,0xe03a2f,0x7a2f9e,0xf07818,0x1d8a4e,0x8e2f3a,
  0x15151a,0xf6c500,0x1f6fd6,0xe03a2f,0x7a2f9e,0xf07818,0x1d8a4e,0x8e2f3a
};

inline std::vector<Ball> rackBalls() {
  std::vector<Ball> b; b.push_back({0,250,H/2,0,0,true});
  const int order[15]={1,9,2,10,8,3,11,4,12,5,13,6,14,7,15};
  int k=0; double cx=720, cy=H/2, gap=R*2+0.6;
  for(int row=0;row<5;row++)for(int i=0;i<=row;i++)
    b.push_back({order[k++], cx+row*gap*0.87, cy+(i-row/2.0)*gap, 0,0,true});
  return b;
}
inline int groupOf(int id){ return id==0?-1: id==8?8: id<8?0:1; } // 0 solid,1 stripe,-1 cue,8 eight
inline bool moving(const std::vector<Ball>&b){ for(auto&x:b) if(x.on&&(x.vx!=0||x.vy!=0))return true; return false; }
inline int remaining(const std::vector<Ball>&b,int g){ int n=0; for(auto&x:b) if(x.on&&groupOf(x.id)==g)n++; return n; }
inline std::vector<Ball> legalTargets(const std::vector<Ball>&b,const int groups[2],int p){
  std::vector<Ball> t; int g=groups[p];
  for(auto&x:b){ if(!x.on||x.id==0)continue;
    if(g==-1){ if(x.id!=8)t.push_back(x); }
    else if(remaining(b,g)==0){ if(x.id==8)t.push_back(x); }
    else if(groupOf(x.id)==g)t.push_back(x); }
  return t;
}

struct Record {
  int firstContact=-1; std::vector<int> pots; bool scratch=false;
  std::map<int,std::vector<Vec>> paths; std::vector<Ball> rest; std::vector<Ball> balls;
};

inline void stepWorld(std::vector<Ball>&b,double dt,Record*rec){
  for(auto&x:b){ if(!x.on)continue; double sp=std::hypot(x.vx,x.vy);
    if(sp>0){ double dx=x.vx/sp,dy=x.vy/sp,tStop=sp/DECEL,dist,ns;
      if(tStop<=dt){dist=sp*sp/(2*DECEL);ns=0;} else {dist=sp*dt-0.5*DECEL*dt*dt;ns=sp-DECEL*dt;}
      x.x+=dx*dist;x.y+=dy*dist;x.vx=dx*ns;x.vy=dy*ns;
      if(rec&&rec->paths.count(x.id)&&ns>0)rec->paths[x.id].push_back({x.x,x.y}); } }
  for(auto&x:b){ if(!x.on)continue; for(auto&p:POCKETS) if(std::hypot(x.x-p.x,x.y-p.y)<POCKET){
      x.on=false;x.vx=0;x.vy=0; if(rec){rec->pots.push_back(x.id); if(x.id==0)rec->scratch=true;} break; } }
  for(auto&x:b){ if(!x.on)continue; bool nearP=false;
    for(auto&p:POCKETS) if(std::hypot(x.x-p.x,x.y-p.y)<POCKET+R*0.6){nearP=true;break;}
    if(nearP)continue;
    if(x.x<R){x.x=R;x.vx=std::abs(x.vx)*CUSH;} if(x.x>W-R){x.x=W-R;x.vx=-std::abs(x.vx)*CUSH;}
    if(x.y<R){x.y=R;x.vy=std::abs(x.vy)*CUSH;} if(x.y>H-R){x.y=H-R;x.vy=-std::abs(x.vy)*CUSH;} }
  for(size_t i=0;i<b.size();i++){ Ball&a=b[i]; if(!a.on)continue;
    for(size_t j=i+1;j<b.size();j++){ Ball&c=b[j]; if(!c.on)continue;
      double dx=c.x-a.x,dy=c.y-a.y,d=std::hypot(dx,dy);
      if(d<2*R&&d>1e-6){ double nx=dx/d,ny=dy/d,ov=(2*R-d)/2;
        a.x-=nx*ov;a.y-=ny*ov;c.x+=nx*ov;c.y+=ny*ov;
        double avn=a.vx*nx+a.vy*ny,cvn=c.vx*nx+c.vy*ny;
        if(avn-cvn>0){ double imp=(avn-cvn)*BALL_REST;
          a.vx-=imp*nx;a.vy-=imp*ny;c.vx+=imp*nx;c.vy+=imp*ny;
          if(rec&&rec->firstContact==-1&&(a.id==0||c.id==0))rec->firstContact=(a.id==0?c.id:a.id); } } } }
}
inline void applyShot(std::vector<Ball>&b,const Shot&s){ Ball&c=b[0]; double sp=s.power*MAXV;
  c.vx=std::cos(s.ang)*sp;c.vy=std::sin(s.ang)*sp; }

inline Record simulate(const std::vector<Ball>&balls,const Shot&shot){
  Record rec; rec.balls=balls; applyShot(rec.balls,shot);
  for(auto&x:rec.balls) if(x.on)rec.paths[x.id].push_back({x.x,x.y});
  double t=0; while(moving(rec.balls)&&t<MAXT){ stepWorld(rec.balls,DT,&rec); t+=DT; }
  for(auto&x:rec.balls) if(rec.paths.count(x.id))rec.paths[x.id].push_back({x.x,x.y});
  rec.rest=rec.balls; return rec;
}
inline Record predict(const std::vector<Ball>&b,const Shot&s){ return simulate(b,s); }
inline std::vector<Ball> executeToRest(std::vector<Ball>&b,const Shot&s){
  applyShot(b,s); double t=0; while(moving(b)&&t<MAXT){stepWorld(b,DT,nullptr);t+=DT;} return b; }

inline bool pathClear(const std::vector<Ball>&b,Vec from,Vec to,const std::vector<int>&ignore){
  double dx=to.x-from.x,dy=to.y-from.y,len=std::hypot(dx,dy); if(len<1)return true;
  double nx=dx/len,ny=dy/len;
  for(auto&x:b){ if(!x.on)continue; bool skip=false; for(int id:ignore)if(id==x.id)skip=true; if(skip)continue;
    double px=x.x-from.x,py=x.y-from.y,t=std::max(0.0,std::min(len,px*nx+py*ny));
    if(std::hypot(px-nx*t,py-ny*t)<2*R-1)return false; }
  return true;
}

// mode: 0 aggr, 1 safe, 2 human. Scratch is a hard avoid-foul constraint in every mode.
inline Shot chooseShot(const std::vector<Ball>&balls,const int groups[2],int p,int mode){
  auto targets=legalTargets(balls,groups,p); const Ball&c=balls[0];
  double base= mode==0?1.0: mode==1?0.55:0.68;
  bool haveBest=false; Shot best{0,0.4,0}; double bestSc=0;
  for(auto&t:targets)for(auto&pk:POCKETS){
    double pdx=pk.x-t.x,pdy=pk.y-t.y,pd=std::hypot(pdx,pdy); if(pd<1)continue;
    double gx=t.x-pdx/pd*2*R,gy=t.y-pdy/pd*2*R;
    double adx=gx-c.x,ady=gy-c.y,ad=std::hypot(adx,ady); if(ad<1)continue;
    double ang=std::atan2(ady,adx);
    double cut=std::acos(std::max(-1.0,std::min(1.0,(adx/ad)*(pdx/pd)+(ady/ad)*(pdy/pd))));
    if(cut>1.25)continue;
    if(!pathClear(balls,{c.x,c.y},{gx,gy},{0,t.id}))continue;
    if(!pathClear(balls,{t.x,t.y},{pk.x,pk.y},{t.id,0}))continue;
    double pw=std::min(1.0,base*(0.6+pd/900+cut*0.4));
    Record r=simulate(balls,{ang,pw,0});
    int g=groups[p]; int own=0,opp=0; bool eight=false;
    for(int id:r.pots){ if(id==0)continue; if(id==8){eight=true;continue;}
      if(g==-1?true:groupOf(id)==g)own++; else opp++; }
    bool legalFC = r.firstContact!=-1 && (g==-1? r.firstContact!=8 : (remaining(balls,g)==0? r.firstContact==8 : groupOf(r.firstContact)==g));
    double sc=0;
    if(!legalFC)sc-=60;
    if(r.scratch)sc-=150;
    if(eight)sc+= (g!=-1&&remaining(balls,g)==0&&!r.scratch)?200:-200;
    sc+=own*(mode==0?60:40); sc-=opp*(mode==0?10:50);
    if(mode==0)sc+=pw*25; if(mode==1)sc-=pw*15;
    if(mode==2){sc+=own*15;sc-=std::abs(pw-0.65)*20;}
    sc-=cut*8;
    if(!haveBest||sc>bestSc){haveBest=true;bestSc=sc;best={ang,pw,0};}
  }
  if(haveBest&&bestSc>-50)return best;
  bool haveSaf=false; Shot saf{0,0.4,0}; double safSc=0;
  for(auto&t:targets){ double ang=std::atan2(t.y-c.y,t.x-c.x);
    for(double pw:{0.3,0.45,0.6}){ Record r=simulate(balls,{ang,pw,0}); int g=groups[p];
      bool legal=r.firstContact!=-1&&(g==-1?r.firstContact!=8:(remaining(balls,g)==0?r.firstContact==8:groupOf(r.firstContact)==g));
      double sc=0; if(r.scratch)sc-=150; if(r.firstContact==-1)sc-=80; if(!legal)sc-=60;
      sc-=pw*10; for(int id:r.pots)if(id!=0&&id!=8)sc+=20;
      if(!haveSaf||sc>safSc){haveSaf=true;safSc=sc;saf={ang,pw,0};} } }
  return haveSaf?saf:Shot{0,0.4,0};
}

} // namespace nsr