// Headless RasterIX (rixif) full-pipeline smoke test.
// GL driver -> command stream -> verilated RTL -> framebuffer -> PPM dumps.
// Wiring mirrors example/qtDebug/qtRasterizerFpga (USE_SIMULATION), minus Qt.

#ifdef USE_POLYSTRESS
#include "PolyStress.hpp"
using Scene = PolyStress;
#elif defined(USE_SPRITE_SCENE)
#include "SpriteScene.hpp"
using Scene = SpriteScene;
#else
#include "Minimal.hpp"
using Scene = Minimal;
#endif
#include "CaptureBusConnector.hpp"
#include "NoThreadRunner.hpp"
#include "RIXGL.hpp"
#include "renderer/devicedatauploader/DeviceDataUploader.hpp"
#include "renderer/threadedvertextransformer/ThreadedVertexTransformer.hpp"
#include <cstdint>
#include <cstdio>

static constexpr uint32_t RESOLUTION_W = 480; // spec target (D1)
static constexpr uint32_t RESOLUTION_H = 272;
static constexpr uint32_t FRAMES = 3; // capture: keep gpu_stream.bin replay short

static uint8_t s_framebuffer[RESOLUTION_W * RESOLUTION_H * 3]; // BGR888 from bus connector

static bool writePpm(const char* path)
{
    FILE* f = fopen(path, "wb");
    if (!f)
        return false;
    fprintf(f, "P6\n%u %u\n255\n", RESOLUTION_W, RESOLUTION_H);
    for (uint32_t i = 0; i < RESOLUTION_W * RESOLUTION_H; i++)
    {
        const uint8_t rgb[3] = { s_framebuffer[i * 3 + 2], s_framebuffer[i * 3 + 1], s_framebuffer[i * 3 + 0] };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    return true;
}

int main()
{
    CaptureBusConnector<> busConnector { s_framebuffer, RESOLUTION_W, RESOLUTION_H }; // tees stream -> gpu_stream.bin
    rr::devicedatauploader::DeviceDataUploader device { busConnector };
    rr::NoThreadRunner workerThread {};
    rr::NoThreadRunner uploadThread {};
    rr::threadedvertextransformer::ThreadedVertexTransformer threadedRasterizer { device, workerThread, uploadThread };

    rr::RIXGL::createInstance(threadedRasterizer);
    rr::RIXGL::getInstance().setRenderResolution(RESOLUTION_W, RESOLUTION_H);

    Scene scene {};
    scene.init(RESOLUTION_W, RESOLUTION_H);

    for (uint32_t frame = 0; frame < FRAMES; frame++)
    {
        uint64_t c0 = rr::VerilatorBusConnector<>::s_simCycles;
        scene.draw();
        rr::RIXGL::getInstance().swapDisplayList();
        uint64_t cyc = rr::VerilatorBusConnector<>::s_simCycles - c0;

        char name[64];
        snprintf(name, sizeof(name), "frame_%02u.ppm", frame);
        if (!writePpm(name))
        {
            fprintf(stderr, "FAIL: cannot write %s\n", name);
            return 1;
        }
        // 60 fps budget at 66.67 MHz = 1,111,167 cycles/frame
        double fps = 66.67e6 / (double)(cyc ? cyc : 1);
        printf("frame %u: %llu sim cycles -> %.1f fps (60fps budget=1.11M) -> %s\n",
               frame, (unsigned long long)cyc, fps, name);
        fflush(stdout);
    }

    rr::RIXGL::getInstance().destroy();
    printf("DONE: %u frames\n", FRAMES);
    return 0;
}