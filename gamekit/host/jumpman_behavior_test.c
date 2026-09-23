#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../examples/jumpman/game_jumpman.c"
static int fail, checks;
static void ck(int ok,const char *s){checks++;if(!ok){fail++;printf("FAIL %s\n",s);}}
#define RIGHT 1
#define JUMP 2
typedef struct {jumpman_state st; ml_game_cfg cfg; ml_view view; ml_canvas cv;} fx;
void ml_ctx_emit_event(ml_game_ctx*c,uint16_t e,int32_t v){(void)c;(void)e;(void)v;}
uint32_t ml_ctx_rng(ml_game_ctx*c){(void)c;return 1;}
static int openfx(fx*f){memset(f,0,sizeof* f);f->cfg.panel_w=64;f->cfg.panel_h=32;if(!ml_canvas_init(&f->cv,64,32,NULL))return 0;ml_view_compute(&f->view,64,32,ML_FIT_LETTERBOX,64,32);ml_game_jumpman.init(&f->st,&f->cfg,NULL);ml_game_jumpman.reset(&f->st,NULL);return 1;}
static void closefx(fx*f){ml_canvas_free(&f->cv);} static void ticks(fx*f,int n){while(n--)ml_game_jumpman.update(&f->st,NULL);}
static void inp(fx*f,int c,int v){ml_input_event e;memset(&e,0,sizeof e);e.player_id=1;e.code=c;e.value=v;e.type=ML_INPUT_BUTTON;ml_game_jumpman.input(&f->st,&e,NULL);}
static void flat(fx*f){memset(f->st.surf,JUMP_GROUND_ROW,sizeof f->st.surf);memset(f->st.block,JM_NOBLK,sizeof f->st.block);for(int i=0;i<PIPE_SLOTS;i++)f->st.pipes[i].x=PM_NONE;for(int i=0;i<ENEMY_SLOTS;i++)f->st.enemies[i].kind=EK_NONE;for(int i=0;i<ITEM_SLOTS;i++)f->st.items[i].state=IS_NONE;f->st.px=PLAYER_START_X<<8;f->st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;f->st.vx=f->st.vy=0;f->st.status=JM_PLAYING;f->st.super=0;f->st.invuln=0;f->st.score=f->st.coin_count=0;f->st.jump_held=f->st.jump_queued=0;}
static int bk(const jumpman_state*s,int x){return s->block[x]==JM_NOBLK?0:jm_blk_kind(s->block[x]);}
static void contract(void){fx f;ck(openfx(&f),"open");ck(!strcmp(ml_game_jumpman.id,"jumpman")&&ml_game_jumpman.pref_w==64&&ml_game_jumpman.pref_h==32,"surface");ck(ml_game_jumpman.control_count==4&&ml_game_jumpman.state_size<=ML_SNAPSHOT_MAX-4,"wire budget");ck(f.st.surf[104]==19&&f.st.surf[105]==JM_NONE&&f.st.surf[108]==19&&f.st.surf[217]==JM_NONE,"authored pits");ck(f.st.surf[66]==14&&bk(&f.st,2)==BM_MUSH&&bk(&f.st,7)==BM_COIN&&f.st.enemies[0].kind==EK_GOOMBA,"authored pieces");closefx(&f);}
static void physics(void){fx f;openfx(&f);flat(&f);int g=JUMP_GROUND_ROW-PLAYER_H_SMALL,a=g;inp(&f,JUMP,1);for(int i=0;i<30;i++){ticks(&f,1);if((f.st.py>>8)<a)a=f.st.py>>8;}ck(a<=g-7&&a>=g-9&&f.st.py>>8==g,"jump");inp(&f,JUMP,0);f.st.block[20]=jm_blk_make(BM_COIN,6);f.st.block[21]=jm_blk_make(BM_COIN,6);f.st.px=20<<8;f.st.py=g<<8;f.st.jump_queued=1;ticks(&f,12);ck(bk(&f.st,20)==BM_USED&&f.st.coin_count==1,"question payout");f.st.super=1;f.st.px=30<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SUPER)<<8;f.st.block[30]=jm_blk_make(BM_BRICK,6);f.st.jump_queued=1;ticks(&f,12);ck(bk(&f.st,30)==BM_BROKEN,"brick break");closefx(&f);}
static void damage(void){fx f;openfx(&f);flat(&f);jm_enemy*e=&f.st.enemies[0];e->kind=EK_GOOMBA;e->state=ES_WALK;e->awake=1;e->x=24<<8;e->y=(JUMP_GROUND_ROW-GOOMBA_H)<<8;f.st.px=24<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL-5)<<8;f.st.vy=128;ticks(&f,8);ck(e->state==ES_SQUASH,"goomba stomp");e->kind=EK_SHELL;e->state=ES_SHELL;e->x=30<<8;e->y=(JUMP_GROUND_ROW-SHELL_H)<<8;e->dir=0;f.st.px=28<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;(void)jm_enemy_touch(&f.st,NULL);ck(e->state==ES_SLIDE,"shell kick");closefx(&f);}
static void wire(void){fx f;openfx(&f);uint8_t b[ML_SNAPSHOT_MAX];size_t n=0;fx saved=f;ck(!ml_game_jumpman.snapshot(&f.st,b,sizeof f.st-1,&n),"short snapshot");ck(ml_game_jumpman.snapshot(&f.st,b,sizeof f.st,&n)&&n==sizeof f.st,"snapshot");ticks(&f,2);ml_game_jumpman.restore(&f.st,b,n);ck(memcmp(&f.st,&saved.st,sizeof f.st)==0,"restore");f.st.px=(FLAG_X-PLAYER_W+1)<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;f.st.vx=JM_RUN;ticks(&f,1);ck(f.st.status==JM_WON,"flag finish");closefx(&f);}
int main(void){contract();physics();damage();wire();printf("jumpman: %d checks, %d failures\n",checks,fail);return fail!=0;}
