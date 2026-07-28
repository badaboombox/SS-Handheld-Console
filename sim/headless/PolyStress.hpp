// Special-stage 3D throughput stress: a tessellated, gently-curved surface of
// ~2048 triangles (a representative DS-era 3D poly ceiling is ~1500-2000 polys),
// flat-shaded, depth-tested, filling the screen to a clean framebuffer with no
// 2D layer. Measures RasterIX vertex + fill throughput per frame.
#pragma once
#include "gl.h"
#include "glu.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

class PolyStress
{
    static constexpr int N = 32;                         // NxN cells -> 2*N*N tris
    static constexpr int VN = N + 1;
    static constexpr std::array<float, 4> CLEAR_COLOR { { 0.1f, 0.1f, 0.15f, 0.0f } };

public:
    void init(const uint32_t w, const uint32_t h)
    {
        // curved grid in x/z, height = sin ripple (some depth complexity/overdraw)
        for (int j = 0; j < VN; j++)
            for (int i = 0; i < VN; i++)
            {
                float u = (float)i / N * 2.0f - 1.0f;
                float v = (float)j / N * 2.0f - 1.0f;
                float z = 0.35f * std::sin(u * 3.14159f) * std::cos(v * 3.14159f);
                m_verts.push_back(u * 6.0f);
                m_verts.push_back(v * 6.0f);
                m_verts.push_back(z * 6.0f);
                m_norms.push_back(0.0f); m_norms.push_back(0.0f); m_norms.push_back(1.0f);
            }
        for (int j = 0; j < N; j++)
            for (int i = 0; i < N; i++)
            {
                uint16_t a = j * VN + i, b = a + 1, c = a + VN, d = c + 1;
                m_idx.push_back(a); m_idx.push_back(b); m_idx.push_back(c);
                m_idx.push_back(b); m_idx.push_back(d); m_idx.push_back(c);
            }

        glViewport(0, 0, w, h);
        glDepthRange(0.0, 1.0);
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();
        gluPerspective(45.0, (float)w / (float)h, 1.0, 100.0);
        glEnable(GL_DEPTH_TEST);
        glDepthMask(GL_TRUE);

        GLfloat lp[] = { 2.0f, 2.0f, 6.0f, 0.0f };
        GLfloat ld[] = { 1.2f, 1.0f, 0.8f, 1.0f };
        glLightfv(GL_LIGHT0, GL_DIFFUSE, ld);
        glLightfv(GL_LIGHT0, GL_POSITION, lp);
        glEnable(GL_LIGHT0);
        glEnable(GL_LIGHTING);
    }

    void draw()
    {
        glClearColor(CLEAR_COLOR[0], CLEAR_COLOR[1], CLEAR_COLOR[2], CLEAR_COLOR[3]);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        gluLookAt(0.0f, -9.0f, 7.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f);
        static float t = 0.0f; t += 2.0f;
        glRotatef(t, 0.0f, 0.0f, 1.0f);

        GLfloat col[] = { 0.6f, 0.7f, 1.0f, 1.0f };
        glMaterialfv(GL_FRONT_AND_BACK, GL_DIFFUSE, col);

        glEnableClientState(GL_NORMAL_ARRAY);
        glNormalPointer(GL_FLOAT, 0, m_norms.data());
        glEnableClientState(GL_VERTEX_ARRAY);
        glVertexPointer(3, GL_FLOAT, 0, m_verts.data());
        glDrawElements(GL_TRIANGLES, m_idx.size(), GL_UNSIGNED_SHORT, m_idx.data());
    }

    int triangles() const { return m_idx.size() / 3; }

private:
    std::vector<float>    m_verts;
    std::vector<float>    m_norms;
    std::vector<uint16_t> m_idx;
};
