// Alpha-blended sprite workload test scene:
//   - fullscreen textured BG quad (stand-in for a 2D tile layer, MVP D13 style)
//   - 24 rotated, alpha-blended sprite quads (stand-in for OBJ layer)
//   - rotating textured cube with depth test (stand-in for 3D player/boss)
//   - translucent untextured overlay (stand-in for water/fx alpha layer)
// Exercises: alpha blending (why we locked RasterIX_IF), alpha textures,
// matrix-rotated quads, ortho+perspective mix, depth on/off per pass.

#include "gl.h"
#include "glu.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>

class SpriteScene
{
public:
    void init(const uint32_t w, const uint32_t h)
    {
        m_w = w;
        m_h = h;

        glViewport(0, 0, w, h);
        glDepthRange(0.0, 1.0);

        m_bgTex = makeCheckerTexture(96, 128, 192, 40, 64, 120);   // blue checker
        m_cubeTex = makeCheckerTexture(80, 200, 96, 24, 96, 40);   // green checker
        m_spriteTex = makeRingTexture();                            // orange ring, alpha hole

        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glDisable(GL_LIGHTING);
        glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    }

    void draw()
    {
        m_t += 1.0f;

        glDisable(GL_SCISSOR_TEST);
        glDepthMask(GL_TRUE); // clear needs write access
        glClearColor(0.55f, 0.78f, 0.98f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Pass bisect: SPRITE_PASSES bitmask (1=bg 2=cube 4=sprites 8=overlay), default all
        const char* pm = std::getenv("SPRITE_PASSES");
        const int mask = pm ? std::atoi(pm) : 0xF;
        if (mask & 1) drawBackground();
        if (mask & 2) drawCube();
        if (mask & 4) drawSprites();
        if (mask & 8) drawOverlay();
    }

private:
    static constexpr uint32_t SPRITES = 24;

    // passes 

    void setOrtho()
    {
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        glOrtho(0.0, m_w, m_h, 0.0, -1.0, 1.0);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
    }

    void drawBackground()
    {
        setOrtho();
        glDisable(GL_DEPTH_TEST);
        glDepthMask(GL_FALSE); // RasterIX writes depth even with test off - mask explicitly
        glDisable(GL_BLEND);
        glEnable(GL_TEXTURE_2D);
        glBindTexture(GL_TEXTURE_2D, m_bgTex);

        const float scroll = std::fmod(m_t * 0.02f, 1.0f); // slow BG scroll
        const float v[] = { 0, 0, (float)m_w, 0, (float)m_w, (float)m_h, 0, (float)m_h };
        const float tc[] = { scroll, 0, scroll + 4, 0, scroll + 4, 2, scroll, 2 };
        drawQuad(v, tc);
    }

    void drawCube()
    {
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        gluPerspective(30.0, (float)m_w / (float)m_h, 1.0, 100.0);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        gluLookAt(8.0f, -6.0f, 4.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f);
        glRotatef(m_t * 5.0f, 0.0f, 0.0f, 1.0f);

        glEnable(GL_DEPTH_TEST);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);
        glEnable(GL_TEXTURE_2D);
        glBindTexture(GL_TEXTURE_2D, m_cubeTex);

        static const std::array<float, 72> verts = { {
            -1,1,1,  -1,-1,1,  1,-1,1,  1,1,1,      // +z
            -1,1,-1, -1,-1,-1, -1,-1,1, -1,1,1,     // -x
            1,1,1,   1,-1,1,   1,-1,-1, 1,1,-1,     // +x
            -1,1,-1, -1,1,1,   1,1,1,   1,1,-1,     // +y
            -1,-1,1, -1,-1,-1, 1,-1,-1, 1,-1,1,     // -y
            1,1,-1,  1,-1,-1, -1,-1,-1, -1,1,-1,    // -z
        } };
        static const std::array<float, 48> tex = { {
            0,1, 0,0, 1,0, 1,1,  1,0, 0,0, 0,1, 1,1,  1,1, 0,1, 0,0, 1,0,
            0,0, 0,1, 1,1, 1,0,  0,1, 0,0, 1,0, 1,1,  1,1, 1,0, 0,0, 0,1,
        } };
        static const std::array<uint16_t, 36> idx = { {
            0,1,2, 0,2,3,   4,5,6, 4,6,7,   8,9,10, 8,10,11,
            12,13,14, 12,14,15,  16,17,18, 16,18,19,  20,21,22, 20,22,23,
        } };
        glVertexPointer(3, GL_FLOAT, 0, verts.data());
        glTexCoordPointer(2, GL_FLOAT, 0, tex.data());
        glDrawElements(GL_TRIANGLES, idx.size(), GL_UNSIGNED_SHORT, idx.data());
    }

    void drawSprites()
    {
        setOrtho();
        glDisable(GL_DEPTH_TEST);
        glDepthMask(GL_FALSE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glEnable(GL_TEXTURE_2D);
        glBindTexture(GL_TEXTURE_2D, m_spriteTex);

        static const float v[] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.5f, 0.5f, -0.5f, 0.5f };
        static const float tc[] = { 0, 0, 1, 0, 1, 1, 0, 1 };

        for (uint32_t i = 0; i < SPRITES; i++)
        {
            const float cx = (float)((i % 8) + 0.5f) * (m_w / 8.0f);
            const float cy = (float)((i / 8) + 0.5f) * (m_h / 3.0f)
                + 20.0f * std::sin(0.15f * m_t + (float)i);
            const float angle = m_t * 3.0f + (float)i * 15.0f; // affine-style rotation
            glPushMatrix();
            glTranslatef(cx, cy, 0.0f);
            glRotatef(angle, 0.0f, 0.0f, 1.0f);
            glScalef(40.0f, 40.0f, 1.0f);
            drawQuad(v, tc);
            glPopMatrix();
        }
    }

    void drawOverlay()
    {
        setOrtho();
        glDisable(GL_DEPTH_TEST);
        glDepthMask(GL_FALSE);
        glDisable(GL_TEXTURE_2D);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glColor4f(0.1f, 0.3f, 0.9f, 0.45f); // translucent "water" band

        const float y0 = m_h * 0.72f;
        const float v[] = { 0, y0, (float)m_w, y0, (float)m_w, (float)m_h, 0, (float)m_h };
        const float tc[] = { 0, 0, 1, 0, 1, 1, 0, 1 }; // unused (texture off)
        drawQuad(v, tc);

        glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
        glDisable(GL_BLEND);
    }

    // helpers 

    void drawQuad(const float* v, const float* tc)
    {
        static const std::array<uint16_t, 6> idx = { { 0, 1, 2, 0, 2, 3 } };
        glVertexPointer(2, GL_FLOAT, 0, v);
        glTexCoordPointer(2, GL_FLOAT, 0, tc);
        glDrawElements(GL_TRIANGLES, idx.size(), GL_UNSIGNED_SHORT, idx.data());
    }

    GLuint makeCheckerTexture(uint8_t r0, uint8_t g0, uint8_t b0, uint8_t r1, uint8_t g1, uint8_t b1)
    {
        static constexpr uint32_t N = 64;
        uint8_t px[N * N * 4];
        for (uint32_t y = 0; y < N; y++)
        {
            for (uint32_t x = 0; x < N; x++)
            {
                const bool a = ((x / 8) ^ (y / 8)) & 1;
                uint8_t* p = &px[(y * N + x) * 4];
                p[0] = a ? r0 : r1;
                p[1] = a ? g0 : g1;
                p[2] = a ? b0 : b1;
                p[3] = 255;
            }
        }
        return uploadTexture(px, N, GL_REPEAT);
    }

    GLuint makeRingTexture()
    {
        static constexpr uint32_t N = 32;
        uint8_t px[N * N * 4];
        for (uint32_t y = 0; y < N; y++)
        {
            for (uint32_t x = 0; x < N; x++)
            {
                const float dx = (float)x - N / 2.0f + 0.5f;
                const float dy = (float)y - N / 2.0f + 0.5f;
                const float d = std::sqrt(dx * dx + dy * dy);
                uint8_t* p = &px[(y * N + x) * 4];
                if (d < 6.0f) // hole
                {
                    p[0] = p[1] = p[2] = p[3] = 0;
                }
                else if (d < 14.0f) // ring body
                {
                    p[0] = 255;
                    p[1] = 170;
                    p[2] = 20;
                    p[3] = 255;
                }
                else // outside
                {
                    p[0] = p[1] = p[2] = p[3] = 0;
                }
            }
        }
        return uploadTexture(px, N, GL_CLAMP_TO_EDGE);
    }

    GLuint uploadTexture(const uint8_t* px, uint32_t n, GLint wrap)
    {
        GLuint id = 0;
        glGenTextures(1, &id);
        glBindTexture(GL_TEXTURE_2D, id);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, n, n, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap);
        return id;
    }

    uint32_t m_w = 0;
    uint32_t m_h = 0;
    float m_t = 0.0f;
    GLuint m_bgTex = 0;
    GLuint m_cubeTex = 0;
    GLuint m_spriteTex = 0;
};