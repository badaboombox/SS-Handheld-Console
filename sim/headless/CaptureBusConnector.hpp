// VerilatorBusConnector subclass that tees every command-stream block the
// driver sends into gpu_stream.bin. The dump is the exact word sequence the
// STM32 would push through the FMC STREAM window, so sim/gpu can replay it
// against the full SoC (FrameStreamingCore's protocol is length-framed;
// block boundaries need not be preserved).

#ifndef CAPTUREBUSCONNECTOR_H
#define CAPTUREBUSCONNECTOR_H

#include "VerilatorBusConnector.hpp"
#include <cstdio>

template <uint32_t NUMBER_OF_DISPLAY_LISTS = 33, uint32_t DISPLAY_LIST_SIZE = 128 * 1024>
class CaptureBusConnector : public rr::VerilatorBusConnector<NUMBER_OF_DISPLAY_LISTS, DISPLAY_LIST_SIZE>
{
public:
    CaptureBusConnector(tcb::span<uint8_t> framebuffer, const uint16_t w, const uint16_t h)
        : rr::VerilatorBusConnector<NUMBER_OF_DISPLAY_LISTS, DISPLAY_LIST_SIZE>(framebuffer, w, h)
    {
        m_dump = fopen("gpu_stream.bin", "wb");
    }

    virtual ~CaptureBusConnector()
    {
        if (m_dump)
            fclose(m_dump);
    }

    virtual void writeData(const uint8_t index, const uint32_t size, const uint32_t offset) override
    {
        if (m_dump)
        {
            fwrite(this->m_dlMemTx[index].data() + offset, 1, size & ~3u, m_dump);
            fflush(m_dump);
        }
        rr::VerilatorBusConnector<NUMBER_OF_DISPLAY_LISTS, DISPLAY_LIST_SIZE>::writeData(index, size, offset);
    }

private:
    FILE* m_dump = nullptr;
};

#endif