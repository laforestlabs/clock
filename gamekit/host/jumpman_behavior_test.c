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
static void flat(fx*f){memset(f->st.surf,JUMP_GROUND_ROW,sizeof f->st.surf);memset(f->st.block,JM_NOBLK,sizeof f->st.block);for(int i=0;i<PIPE_SLOTS;i++)f->st.pipes[i].x=PM_NONE;for(int i=0;i<ENEMY_SLOTS;i++)f->st.enemies[i].kind=EK_NONE;for(int i=0;i<ITEM_SLOTS;i++)f->st.items[i].state=IS_NONE;f->st.px=jm_state_level(&f->st)->start_x<<8;f->st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;f->st.vx=f->st.vy=0;f->st.status=JM_PLAYING;f->st.super=0;f->st.invuln=0;f->st.score=f->st.coin_count=0;f->st.jump_held=f->st.jump_queued=0;}
static int bk(const jumpman_state*s,int x){return s->block[x]==JM_NOBLK?0:jm_blk_kind(s->block[x]);}

/* The level resolved the way jm_load_level resolves it: runs in order, a later
 * run superseding an earlier one over the columns it covers, and a record that
 * could not be part of a level ignored. This is the shape half of the level
 * contract, and it holds for whatever level is current - the authored tables or
 * one a test handed in. */
static void resolve(const jm_level*lv,uint8_t*surf,uint8_t*block)
{
    memset(surf,JM_NONE,JUMP_COLS);
    memset(block,JM_NOBLK,JUMP_COLS);
    for(int i=0;i<lv->ground_n;i++){
        const jm_ground_def*g=&lv->ground[i];
        if(g->w==0||(int)g->x+(int)g->w>JUMP_COLS)continue;
        if(g->surf==JML_PIT)continue;
        for(int x=g->x;x<(int)g->x+(int)g->w;x++)surf[x]=g->surf;
    }
    for(int i=0;i<lv->pipes_n;i++){
        const jm_pipe_def*p=&lv->pipes[i];
        if(p->h==0||(int)p->x+PIPE_W>JUMP_COLS)continue;
        for(int x=p->x;x<(int)p->x+PIPE_W;x++)surf[x]=(uint8_t)(JUMP_GROUND_ROW-(int)p->h);
    }
    for(int i=0;i<lv->blocks_n;i++){
        const jm_block_def*b=&lv->blocks[i];
        if(b->w==0||(int)b->x+(int)b->w>JUMP_COLS)continue;
        for(int k=0;k<(int)b->w;k++)block[b->x+k]=jm_blk_make(b->kind,b->row);
    }
}

/* Every pit the level states is a pit in the state, over the whole run: the
 * ground the tables describe and the ground the state holds are one thing,
 * whatever level the tables happen to describe. */
static int pits_are_pits(const jm_level*lv,const uint8_t*surf)
{
    for(int i=0;i<lv->ground_n;i++){
        const jm_ground_def*g=&lv->ground[i];
        if(g->w==0||(int)g->x+(int)g->w>JUMP_COLS)continue;
        if(g->surf!=JML_PIT)continue;
        for(int x=g->x;x<(int)g->x+(int)g->w;x++)if(surf[x]!=JM_NONE)return 0;
    }
    return 1;
}

/* Every enemy the level states is standing in the state, by column and kind. */
static int enemies_spawn(const jm_level*lv,const jumpman_state*s)
{
    for(int i=0;i<lv->enemies_n;i++){
        const jm_enemy_def*d=&lv->enemies[i];
        if(!jm_col_inside(d->x)||(int)d->row>=JUMP_ROWS)continue;
        int found=0;
        for(int j=0;j<ENEMY_SLOTS&&!found;j++)
            found=s->enemies[j].kind==d->kind&&(s->enemies[j].x>>8)==d->x;
        if(!found)return 0;
    }
    return 1;
}

static void contract(void){
    fx f;uint8_t surf[JUMP_COLS],block[JUMP_COLS];
    const jm_level*lv=&jm_level_authored;
    ck(openfx(&f),"open");
    ck(!strcmp(ml_game_jumpman.id,"jumpman")&&ml_game_jumpman.pref_w==64&&ml_game_jumpman.pref_h==32,"surface");
    ck(ml_game_jumpman.control_count==4&&ml_game_jumpman.state_size<=ML_SNAPSHOT_MAX-4,"wire budget");
    /* The state is the level, column for column, and within the slots the game
     * holds - asserted off the level value rather than off column numbers, so
     * the checks stay true for whatever level the tables state. */
    resolve(lv,surf,block);
    ck(memcmp(f.st.surf,surf,JUMP_COLS)==0,"the state's ground is the level's ground");
    ck(memcmp(f.st.block,block,JUMP_COLS)==0,"the state's blocks are the level's blocks");
    ck(pits_are_pits(lv,f.st.surf),"every pit the level states is a pit in the state");
    ck(enemies_spawn(lv,&f.st),"every enemy the level states is standing in the state");
    ck(f.st.start_x==lv->start_x&&f.st.checkpoint_x==lv->checkpoint_x,"the state's columns are the level's");
    ck(lv->ground_n<=JM_GROUND_MAX&&lv->blocks_n<=JM_BLOCK_MAX&&lv->pipes_n<=PIPE_SLOTS
       &&lv->coins_n<=COIN_SLOTS&&lv->enemies_n<=ENEMY_SLOTS,"the tables fit their slots");
    closefx(&f);
}
static void physics(void){fx f;openfx(&f);flat(&f);int g=JUMP_GROUND_ROW-PLAYER_H_SMALL,a=g;inp(&f,JUMP,1);for(int i=0;i<30;i++){ticks(&f,1);if((f.st.py>>8)<a)a=f.st.py>>8;}ck(a<=g-7&&a>=g-9&&f.st.py>>8==g,"jump");inp(&f,JUMP,0);f.st.block[20]=jm_blk_make(BM_COIN,6);f.st.block[21]=jm_blk_make(BM_COIN,6);f.st.px=20<<8;f.st.py=g<<8;f.st.jump_queued=1;ticks(&f,12);ck(bk(&f.st,20)==BM_USED&&f.st.coin_count==1,"question payout");f.st.super=1;f.st.px=30<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SUPER)<<8;f.st.block[30]=jm_blk_make(BM_BRICK,6);f.st.jump_queued=1;ticks(&f,12);ck(bk(&f.st,30)==BM_BROKEN,"brick break");closefx(&f);}
static void damage(void){fx f;openfx(&f);flat(&f);jm_enemy*e=&f.st.enemies[0];e->kind=EK_GOOMBA;e->state=ES_WALK;e->awake=1;e->x=24<<8;e->y=(JUMP_GROUND_ROW-GOOMBA_H)<<8;f.st.px=24<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL-5)<<8;f.st.vy=128;ticks(&f,8);ck(e->state==ES_SQUASH,"goomba stomp");e->kind=EK_SHELL;e->state=ES_SHELL;e->x=30<<8;e->y=(JUMP_GROUND_ROW-SHELL_H)<<8;e->dir=0;f.st.px=28<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;(void)jm_enemy_touch(&f.st,NULL);ck(e->state==ES_SLIDE,"shell kick");closefx(&f);}
static void wire(void){fx f;openfx(&f);uint8_t b[ML_SNAPSHOT_MAX];size_t n=0;fx saved=f;ck(!ml_game_jumpman.snapshot(&f.st,b,sizeof f.st-1,&n),"short snapshot");ck(ml_game_jumpman.snapshot(&f.st,b,sizeof f.st,&n)&&n==sizeof f.st,"snapshot");ticks(&f,2);ml_game_jumpman.restore(&f.st,b,n);ck(memcmp(&f.st,&saved.st,sizeof f.st)==0,"restore");closefx(&f);}

/* Put the player on the flagpole's first column, running into it. */
static void at_flag(fx*f){f->st.px=(FLAG_X-PLAYER_W+1)<<8;f->st.py=(JUMP_GROUND_ROW-play_h(&f->st))<<8;f->st.vx=JM_RUN;}

/* The campaign: a fresh session is course 1 with 1 unlocked, each course's flag
 * unlocks and hands over to the next with the score and lives intact and no
 * early game over, and only the third flag wins. */
static void campaign(void)
{
    fx f;openfx(&f);
    ck(ml_jumpman_course(&f.st)==1&&ml_jumpman_unlocked(&f.st)==1,"a fresh campaign is course 1, 1 unlocked");
    ck(!ml_game_jumpman.is_over(&f.st),"a fresh campaign is not over");

    f.st.super=1;f.st.score=500;f.st.lives=2;
    at_flag(&f);ticks(&f,1);
    ck(f.st.status==JM_TRANS,"course 1's flag opens the transition");
    ck(ml_jumpman_course(&f.st)==2&&ml_jumpman_unlocked(&f.st)==2,"course 2 is unlocked and current");
    ck(f.st.checkpoint==0,"the transition clears the checkpoint");
    ck(f.st.score>=500&&f.st.lives==2,"score and lives carry into the next course");
    ck(!ml_game_jumpman.is_over(&f.st),"no course before the last ends the run");
    ticks(&f,TRANS_TICKS);
    ck(f.st.status==JM_PLAYING&&f.st.super==0&&f.st.invuln==0,"the next course begins unpowered");
    ck((f.st.px>>8)==jm_level_pipe_garden.start_x,"course 2 starts at its own column");
    ck(f.st.surf[44]==JUMP_GROUND_ROW-3&&f.st.pipes[0].x==44,"course 2's first pipe is built");
    ck(f.st.surf[0]==JUMP_GROUND_ROW,"course 2's plain ground is in the state");
    ck(ml_jumpman_course(&f.st)==2,"still course 2 after the banner");

    f.st.score=900;
    at_flag(&f);ticks(&f,1);
    ck(f.st.status==JM_TRANS&&ml_jumpman_course(&f.st)==3&&ml_jumpman_unlocked(&f.st)==3,"course 3 is unlocked");
    ck(!ml_game_jumpman.is_over(&f.st),"course 3 is not over on arrival");
    ticks(&f,TRANS_TICKS);
    ck(f.st.status==JM_PLAYING&&(f.st.px>>8)==jm_level_koopa_quarry.start_x,"course 3 plays");
    ck(f.st.surf[40]==16&&f.st.surf[70]==JM_NONE,"course 3's shelf and pit are built");

    at_flag(&f);ticks(&f,1);
    ck(f.st.status==JM_WON&&ml_game_jumpman.is_over(&f.st),"the third flag is the win");
    ck(ml_jumpman_unlocked(&f.st)==3,"the win unlocks nothing past the campaign");
    ck(f.st.score>=900,"the win's flag pays");
    closefx(&f);
}

/* An explicit course start: any unlocked course may begin a run, a locked or
 * nonsense one is refused with the state untouched, and a start is a fresh run
 * of three lives and no score. */
static void refusal(void)
{
    fx f;openfx(&f);
    ck(!ml_jumpman_start_course(NULL,1,1),"no state, no start");
    ck(ml_jumpman_start_course(&f.st,2,2),"course 2 of 2 unlocked starts");
    ck(ml_jumpman_course(&f.st)==2&&ml_jumpman_unlocked(&f.st)==2,"course 2 is selected");
    ck(ml_game_jumpman_state_int(&f.st,"status")==JM_PLAYING,"a started course is being played");
    ck((f.st.px>>8)==jm_level_pipe_garden.start_x&&f.st.surf[44]==JUMP_GROUND_ROW-3,
       "the selected course's level is loaded");
    const uint8_t course=f.st.course,unlocked=f.st.unlocked;const uint16_t score=f.st.score;const uint8_t lives=f.st.lives;
    ck(!ml_jumpman_start_course(&f.st,3,2),"a locked course is refused");
    ck(!ml_jumpman_start_course(&f.st,0,3),"course 0 is not a course");
    ck(!ml_jumpman_start_course(&f.st,ML_JUMPMAN_COURSES+1,ML_JUMPMAN_COURSES+1),"past the last course is refused");
    ck(!ml_jumpman_start_course(&f.st,2,0),"an unlocked count below one is refused");
    ck(!ml_jumpman_start_course(&f.st,2,ML_JUMPMAN_COURSES+1),"an unlocked count past the campaign is refused");
    ck(f.st.course==course&&f.st.unlocked==unlocked&&f.st.score==score&&f.st.lives==lives
       &&(f.st.px>>8)==jm_level_pipe_garden.start_x,"a refused start changes nothing");
    f.st.score=2500;f.st.lives=1;f.st.super=1;
    ck(ml_jumpman_start_course(&f.st,3,3),"the last course starts when unlocked");
    ck(ml_jumpman_course(&f.st)==3&&f.st.lives==3&&f.st.score==0&&f.st.super==0,
       "a new start is a fresh run");
    ck((f.st.px>>8)==jm_level_koopa_quarry.start_x&&f.st.surf[40]==16&&f.st.surf[70]==JM_NONE,
       "course 3's level is loaded");
    closefx(&f);
}

/* A death keeps the course and, once passed, the checkpoint; it resets the
 * power-up and costs a life, and running out of lives ends the run - course and
 * unlock intact, so a host can still persist what the player reached. */
static void death_replay(void)
{
    fx f;openfx(&f);
    ck(ml_jumpman_start_course(&f.st,2,2),"start course 2");
    f.st.checkpoint=1;f.st.score=777;f.st.lives=3;f.st.super=1;
    f.st.status=JM_DYING;f.st.dying=1;f.st.vy=0;
    ticks(&f,1);
    ck(f.st.status==JM_PLAYING&&f.st.lives==2,"a death costs a life and rebuilds the level");
    ck(ml_jumpman_course(&f.st)==2,"the death keeps the course");
    ck(f.st.checkpoint==1&&(f.st.px>>8)==jm_level_pipe_garden.checkpoint_x,
       "the death restarts at the checkpoint");
    ck(f.st.super==0&&f.st.invuln==0,"the death drops the power-up");
    ck(f.st.score==777,"the score carries through a death");
    f.st.lives=1;f.st.status=JM_DYING;f.st.dying=1;f.st.vy=0;
    ticks(&f,1);
    ck(f.st.status==JM_OVER&&ml_game_jumpman.is_over(&f.st),"no lives ends the run");
    ck(ml_jumpman_course(&f.st)==2&&ml_jumpman_unlocked(&f.st)==2,"game over keeps the course and unlock");
    closefx(&f);
}

/* A snapshot carries the course and the unlock count, so a peer restored onto a
 * course reloads that course, not the first one. */
static void snapshot_course(void)
{
    fx f;openfx(&f);uint8_t b[ML_SNAPSHOT_MAX];size_t n=0;
    ck(ml_jumpman_start_course(&f.st,2,3),"start course 2 with 3 unlocked");
    f.st.px=(FLAG_X-PLAYER_W+1)<<8;f.st.score=1234;
    ck(ml_game_jumpman.snapshot(&f.st,b,sizeof f.st,&n),"snapshot a campaign run");

    fx peer;memset(&peer,0,sizeof peer);
    ml_game_jumpman.init(&peer.st,&f.cfg,NULL);
    ck(ml_jumpman_course(&peer.st)==0,"a session that has not started has no course");
    ml_game_jumpman.restore(&peer.st,b,n);
    ck(ml_jumpman_course(&peer.st)==2&&ml_jumpman_unlocked(&peer.st)==3,
       "a restored snapshot carries the course and the unlock");
    ck((peer.st.px>>8)==(FLAG_X-PLAYER_W+1)&&peer.st.score==1234,"and the run");
    peer.st.lives=2;peer.st.status=JM_DYING;peer.st.dying=1;peer.st.vy=0;
    ticks(&peer,1);
    ck(ml_jumpman_course(&peer.st)==2&&peer.st.lives==1,"a death after a restore keeps the course");
    ck(peer.st.surf[44]==JUMP_GROUND_ROW-3,"and reloads that course's level");
    closefx(&f);
}

/* Authored shells wait to be kicked; they must not creep into the player as
 * walkers before contact. Exercise the shell in the real quarry course. */
static void quarry_shell(void)
{
    fx f;openfx(&f);
    ck(ml_jumpman_start_course(&f.st,3,3),"open quarry");
    jm_enemy *shell=NULL;
    for(int i=0;i<ENEMY_SLOTS;i++)
        if(f.st.enemies[i].kind==EK_SHELL) shell=&f.st.enemies[i];
    ck(shell!=NULL,"quarry has its authored shell");
    if(shell){
        const int32_t x=shell->x;
        shell->awake=1;
        for(int i=0;i<12;i++)jm_update_enemies(&f.st,NULL);
        ck(shell->x==x,"an un-kicked quarry shell stays in place");
        f.st.px=x-((PLAYER_W-1)<<8);
        f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;
        ck(!jm_enemy_touch(&f.st,NULL),"touching the resting shell kicks, not hurts");
        for(int i=0;i<3;i++)jm_update_enemies(&f.st,NULL);
        ck(shell->x>x,"the kicked shell slides away from the player");
    }
    closefx(&f);
}

/* ---- a level handed in, the way the editor hands one in ----------------- */

/* A tiny level in the wire form: ground 0..40 at row 19, a pit 41..70, ground
 * 71..255, start 5, checkpoint 100, no blocks, pipes, coins or enemies. */
static size_t tiny_blob(uint8_t*b)
{
    uint8_t*p=b;
    *p++=1;  *p++=5;   *p++=100;
    *p++=3;  *p++=0;   *p++=0;  *p++=0;  *p++=0;
    *p++=0;  *p++=41;  *p++=19;
    *p++=41; *p++=30;  *p++=JML_PIT;
    *p++=71; *p++=185; *p++=19;
    return (size_t)(p-b);
}
static void injected(void)
{
    fx f;uint8_t b[64];const size_t n=tiny_blob(b);
    ck(ml_game_jumpman_set_level(b,n),"a level handed in is accepted");
    ck(openfx(&f),"a session opens on the level it was given");
    ck(f.st.surf[40]==19&&f.st.surf[41]==JM_NONE&&f.st.surf[70]==JM_NONE&&f.st.surf[71]==19,"the injected ground");
    ck(f.st.start_x==5&&f.st.checkpoint_x==100&&(f.st.px>>8)==5,"the injected columns");
    ck(ml_jumpman_course(&f.st)==0&&ml_jumpman_unlocked(&f.st)==0,"an injected level is not a campaign");
    /* Its flag is its win and unlocks nothing: the editor's playtest must not
     * move a player's campaign forward. */
    f.st.px=(FLAG_X-PLAYER_W+1)<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;f.st.vx=JM_RUN;
    ticks(&f,1);
    ck(f.st.status==JM_WON&&ml_game_jumpman.is_over(&f.st),"an injected level's flag is its win");
    ck(ml_jumpman_course(&f.st)==0&&ml_jumpman_unlocked(&f.st)==0,"and it unlocks nothing");
    /* An explicit course start leaves the injected mode for the campaign even
     * while the override is still the current level. */
    ck(ml_jumpman_start_course(&f.st,1,1),"a course start takes over an injected session");
    ck(ml_jumpman_course(&f.st)==1&&(f.st.px>>8)==jm_level_authored.start_x,"and plays course 1");
    ck(f.st.surf[105]==JM_NONE&&f.st.surf[0]==JUMP_GROUND_ROW,"course 1's terrain, not the injected level's");
    closefx(&f);
}
static void refused(void)
{
    fx f;uint8_t b[64],surf[JUMP_COLS],block[JUMP_COLS];size_t n=tiny_blob(b);
    ck(ml_game_jumpman_set_level(b,n),"a reference level is accepted");
    const jm_level*before=jm_level_now;

    b[0]=2;
    ck(!ml_game_jumpman_set_level(b,n)&&jm_level_now==before,"a version this game does not read is refused");

    n=tiny_blob(b);b[5]=(uint8_t)(PIPE_SLOTS+1);
    ck(!ml_game_jumpman_set_level(b,n)&&jm_level_now==before,"more pipes than slots is refused");

    n=tiny_blob(b);b[8]=10;b[9]=250;
    ck(!ml_game_jumpman_set_level(b,n)&&jm_level_now==before,"a run past the last column is refused");

    n=tiny_blob(b);
    ck(!ml_game_jumpman_set_level(b,n-1)&&jm_level_now==before,"a blob one byte short is refused");

    n=tiny_blob(b);b[7]=1;b[n]=5;b[n+1]=JUMP_ROWS;b[n+2]=(uint8_t)-1;b[n+3]=EK_GOOMBA;n+=4;
    ck(!ml_game_jumpman_set_level(b,n)&&jm_level_now==before,"an enemy under the field is refused");

    ck(ml_game_jumpman_set_level(NULL,0),"the empty blob gives the authored level back");
    ck(jm_level_now==&jm_level_authored,"the authored level is current again");
    ck(openfx(&f),"reopen");
    resolve(&jm_level_authored,surf,block);
    ck(memcmp(f.st.surf,surf,JUMP_COLS)==0
       &&f.st.start_x==jm_level_authored.start_x
       &&f.st.checkpoint_x==jm_level_authored.checkpoint_x,"a reload builds the authored level");
    closefx(&f);
}
static void readout(void)
{
    fx f;openfx(&f);
    f.st.px=42<<8;f.st.cam=7;f.st.lives=2;f.st.status=JM_DYING;
    ck(ml_game_jumpman_state_int(&f.st,"player_x")==42,"player_x");
    ck(ml_game_jumpman_state_int(&f.st,"camera")==7,"camera");
    ck(ml_game_jumpman_state_int(&f.st,"lives")==2,"lives");
    ck(ml_game_jumpman_state_int(&f.st,"status")==JM_DYING,"status");
    ck(ml_game_jumpman_state_int(&f.st,"nonsense")==-1,"a name this game does not publish");
    ck(ml_game_jumpman_state_int(NULL,"lives")==-1,"no state at all");

    /* A bot plays the level through these three, so they have to mean what it
     * thinks they mean: where the player is, whether it is standing, and how far
     * away the nearest enemy in its way is. */
    flat(&f);
    f.st.px=40<<8;f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;
    ck(ml_game_jumpman_state_int(&f.st,"player_y")==JUMP_GROUND_ROW-PLAYER_H_SMALL,"player_y");
    ck(ml_game_jumpman_state_int(&f.st,"on_ground")==1,"on_ground on the ground");
    f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL-6)<<8;
    ck(ml_game_jumpman_state_int(&f.st,"on_ground")==0,"on_ground in the air");
    ck(ml_game_jumpman_state_int(&f.st,"enemy_gap")==-1,"no enemy near");
    /* Back on the ground: an enemy is only in the way of a body it overlaps. */
    f.st.py=(JUMP_GROUND_ROW-PLAYER_H_SMALL)<<8;
    jm_enemy*e=&f.st.enemies[0];
    e->kind=EK_GOOMBA;e->state=ES_WALK;e->x=48<<8;e->y=(JUMP_GROUND_ROW-GOOMBA_H)<<8;
    ck(ml_game_jumpman_state_int(&f.st,"enemy_gap")==8,"an enemy eight columns ahead");
    e->x=30<<8;
    ck(ml_game_jumpman_state_int(&f.st,"enemy_gap")==-1,"an enemy behind the player");
    e->x=200<<8;
    ck(ml_game_jumpman_state_int(&f.st,"enemy_gap")==-1,"an enemy out of reach");
    e->x=48<<8;e->state=ES_SQUASH;
    ck(ml_game_jumpman_state_int(&f.st,"enemy_gap")==-1,"a squashed enemy is ignored");

    /* The pipe's plant, which a bot has to wait out: how many rows it has out,
     * and nothing at all for a pipe that is behind the player. */
    f.st.pipes[0].x=46;f.st.pipes[0].top=JUMP_GROUND_ROW-5;f.st.pipes[0].plant=1;
    f.st.pipes[0].phase=0;
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")==0,"a hidden plant");
    f.st.pipes[0].phase=70;   /* fully out */
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")==PLANT_ROWS,"a risen plant");
    f.st.pipes[0].phase=50;   /* coming up */
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")>0,"a plant on its way up");
    f.st.pipes[0].plant=0;
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")==0,"a pipe with no plant");
    f.st.pipes[0].plant=1;f.st.pipes[0].x=20;
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")==0,"a plant behind the player");
    f.st.pipes[0].x=40+ENEMY_WAKE+8;
    ck(ml_game_jumpman_state_int(&f.st,"plant_out")==0,"a plant too far ahead to matter");
    closefx(&f);
}

int main(void){contract();physics();damage();wire();campaign();refusal();death_replay();snapshot_course();quarry_shell();injected();refused();readout();printf("jumpman: %d checks, %d failures\n",checks,fail);return fail!=0;}
