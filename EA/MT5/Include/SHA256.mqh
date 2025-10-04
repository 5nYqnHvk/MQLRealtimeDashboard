//+------------------------------------------------------------------+
//|                                                      SHA256+HMAC |
//| http://www.zedwood.com/article/cpp-sha256-function               |
//| https://ru.wikipedia.org/wiki/HMAC                               |
//+------------------------------------------------------------------+
#property link      "http://www.zedwood.com/article/cpp-sha256-function"
#property version   "1.00"
#property strict

#define SHA224_256_BLOCK_SIZE	64 //=512/8

#ifndef __SHA256__
#define __SHA256__
#define DIGEST_256_SIZE	32 //=256/8
#define SHA256_F1(x) (SHA2_ROTR(x,  2) ^ SHA2_ROTR(x, 13) ^ SHA2_ROTR(x, 22))
#define SHA256_F2(x) (SHA2_ROTR(x,  6) ^ SHA2_ROTR(x, 11) ^ SHA2_ROTR(x, 25))
#define SHA256_F3(x) (SHA2_ROTR(x,  7) ^ SHA2_ROTR(x, 18) ^ SHA2_SHFR(x,  3))
#define SHA256_F4(x) (SHA2_ROTR(x, 17) ^ SHA2_ROTR(x, 19) ^ SHA2_SHFR(x, 10))
#endif

#ifndef __SHA2__
#define __SHA2__
#define SHA2_SHFR(x, n)    (x >> n)
#define SHA2_ROTR(x, n)   ((x >> n) | (x << ((sizeof(x) << 3) - n)))
#define SHA2_ROTL(x, n)   ((x << n) | (x >> ((sizeof(x) << 3) - n)))
#define SHA2_CH(x, y, z)  ((x & y) ^ (~x & z))
#define SHA2_MAJ(x, y, z) ((x & y) ^ (x & z) ^ (y & z))
#endif
//+------------------------------------------------------------------+
class SHA256
  {
protected:
   static uint       sha256_k[64];
   uint              m_tot_len,m_len;
   uchar             m_block[2*SHA224_256_BLOCK_SIZE];
   uint              m_h[8];

public:

   //+------------------------------------------------------------------+
   void init()
     {
      m_h[0] = 0x6a09e667;
      m_h[1] = 0xbb67ae85;
      m_h[2] = 0x3c6ef372;
      m_h[3] = 0xa54ff53a;
      m_h[4] = 0x510e527f;
      m_h[5] = 0x9b05688c;
      m_h[6] = 0x1f83d9ab;
      m_h[7] = 0x5be0cd19;

      m_len=0; m_tot_len=0;
     }
   //+------------------------------------------------------------------+
   void update(const uchar &message[],uint len)
     {
      uint tmp_len=SHA224_256_BLOCK_SIZE-m_len;
      uint rem_len=len<tmp_len?len:tmp_len;
      ArrayCopy(m_block,message,m_len,0,rem_len); //memcpy(&m_block[m_len], message, rem_len);
      if(m_len+len<SHA224_256_BLOCK_SIZE) { m_len+=len; return; }
      uint new_len=len-rem_len;
      uint block_nb=new_len/SHA224_256_BLOCK_SIZE;
      uchar shifted_message[];
      ArrayCopy(shifted_message,message,0,rem_len); //shifted_message=message + rem_len;
      transform(m_block,1);
      transform(shifted_message,block_nb);
      rem_len=new_len%SHA224_256_BLOCK_SIZE;
      ArrayCopy(m_block,shifted_message,0,block_nb<<6,rem_len); //memcpy(m_block, &shifted_message[block_nb << 7], rem_len);
      m_len=rem_len;
      m_tot_len+=(block_nb+1)<<6;
     }
   //+------------------------------------------------------------------+
   void end(uchar &digest[])
     {
      uint block_nb=1+((SHA224_256_BLOCK_SIZE-9)<(m_len%SHA224_256_BLOCK_SIZE));
      uint len_b=(m_tot_len+m_len)<<3;
      uint pm_len=block_nb<<6;
      ArrayFill(m_block,m_len,pm_len-m_len,0); //memset(m_block+m_len, 0, pm_len-m_len);
      m_block[m_len]=0x80;
      SHA2_UNPACK32(len_b,m_block,pm_len-4);
      transform(m_block,block_nb);
      for(int i=0; i<8; i++) SHA2_UNPACK32(m_h[i],digest,i<<2);
     }

protected:
   //+------------------------------------------------------------------+
   void transform(const uchar &message[],uint block_nb)
     {
      for(int i=0; i<(int)block_nb; i++)
        {
         uchar sub_block[];

         ArrayCopy(sub_block,message,0,(i<<6)); //sub_block=message+(i<<7);

         uint w[64]={0};

         for(int j=0; j<16; j++)
            w[j]=SHA2_PACK32(sub_block,j<<2);

         for(int j=16; j<64; j++)
            w[j]=SHA256_F4(w[j-2])+w[j-7]+SHA256_F3(w[j-15])+w[j-16];

         uint wv[8]={0};

         for(int j=0; j<8; j++)
            wv[j]=m_h[j];

         for(int j=0; j<64; j++)
           {
            uint t1=wv[7]+SHA256_F2(wv[4])+SHA2_CH(wv[4], wv[5], wv[6])+sha256_k[j]+w[j];
            uint t2=SHA256_F1(wv[0])+SHA2_MAJ(wv[0], wv[1], wv[2]);
            wv[7]=wv[6];
            wv[6]=wv[5];
            wv[5]=wv[4];
            wv[4]=wv[3]+t1;
            wv[3]=wv[2];
            wv[2]=wv[1];
            wv[1]=wv[0];
            wv[0]=t1+t2;
           }

         for(int j=0; j<8; j++)
            m_h[j]+=wv[j];
        }
     }
   //+------------------------------------------------------------------+
   void SHA2_UNPACK32(uint x,uchar &str[],int s)
     {
      str[s+3]=uchar(x);
      str[s+2]=uchar(x>>8);
      str[s+1]=uchar(x>>16);
      str[s+0]=uchar(x>>24);
     }
   //+------------------------------------------------------------------+
   uint SHA2_PACK32(uchar &str[],int s)
     {
      uint x=uint(str[s+3])|
             (uint(str[s+2])<<8)|
             (uint(str[s+1])<<16)|
             (uint(str[s])<<24);
      return x;
     }
public:
   //+------------------------------------------------------------------+
   static string sha256(string in) { uchar out[]; return sha256(in,out); }
   static string sha256(string in,uchar &out[]) { uchar cin[]; StringToCharArray(in,cin,0,StringLen(in)); return sha256(cin,out); }
   static string sha256(const uchar &in[]) { uchar out[]; return sha256(in,out); }
   static string sha256(const uchar &in[],uchar &out[])
     {
      SHA256 sha;
      sha.init();
      sha.update(in, ArraySize(in));
      uchar digest[DIGEST_256_SIZE]={0};
      sha.end(digest);
      string str;
      ArrayResize(out,DIGEST_256_SIZE);
      for(int i=0; i<DIGEST_256_SIZE; i++)
        {
         str+=StringFormat("%02x",digest[i]);
         out[i]=digest[i];
        }
      return str;
     }
   //+------------------------------------------------------------------+
   static string hmac(string smsg,string skey)
     {
      uint BLOCKSIZE=SHA224_256_BLOCK_SIZE;
      if((uint)StringLen(skey)>BLOCKSIZE)
         skey=sha256(skey);
      uchar key[];
      uint n=(uint)StringToCharArray(skey,key,0,StringLen(skey));
      if(n<BLOCKSIZE)
        {
         ArrayResize(key,BLOCKSIZE);
         ArrayFill(key,n,BLOCKSIZE-n,0);
        }

      uchar i_key_pad[];
      ArrayCopy(i_key_pad,key);
      for(uint i=0; i<BLOCKSIZE; i++)
         i_key_pad[i]=key[i]^(uchar)0x36;

      uchar o_key_pad[];
      ArrayCopy(o_key_pad,key);
      for(uint i=0; i<BLOCKSIZE; i++)
         o_key_pad[i]=key[i]^(uchar)0x5c;

      uchar msg[]; n=(uint)StringToCharArray(smsg,msg,0,StringLen(smsg));
      uchar i_s[];
      ArrayResize(i_s,BLOCKSIZE+n);
      ArrayCopy(i_s,i_key_pad);
      ArrayCopy(i_s,msg,BLOCKSIZE);

      uchar i_sha256[];
      string is=sha256(i_s,i_sha256);
      uchar o_s[];
      ArrayResize(o_s,BLOCKSIZE+ArraySize(i_sha256));
      ArrayCopy(o_s,o_key_pad);
      ArrayCopy(o_s,i_sha256,BLOCKSIZE);

      string o_sha256=sha256(o_s);

      return o_sha256;
     }
  };
//+------------------------------------------------------------------+
uint SHA256::sha256_k[64]=
  {
   0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
   0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
   0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
   0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
   0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
   0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
   0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
   0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
   0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
   0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
   0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
   0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
   0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
   0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
   0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
   0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  };
//+------------------------------------------------------------------+
