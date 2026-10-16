// Original offline D3D12 smoke sample. No Steam, game assets, or Apple binaries.
#define COBJMACROS
#define UNICODE
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>

#define CHECK(call) do { HRESULT result = (call); if (FAILED(result)) { \
    printf("%s failed: %08lx\n", #call, (unsigned long)result); fflush(stdout); return 1; } } while (0)

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l)
{
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, w, l);
}

int main(int argc, char **argv)
{
    WNDCLASSW window_class = {.lpfnWndProc = window_proc, .hInstance = GetModuleHandleW(NULL),
        .lpszClassName = L"PuffletD3D12Smoke", .hCursor = LoadCursorW(NULL, IDC_ARROW)};
    RegisterClassW(&window_class);
    HWND window = CreateWindowW(window_class.lpszClassName, L"Pufflet — DirectX 12 smoke sample",
        WS_OVERLAPPEDWINDOW, 100, 100, 800, 540, NULL, NULL, window_class.hInstance, NULL);
    if (!window) return 1;
    ID3D12Device *device = NULL;
    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));
    HMODULE module = GetModuleHandleW(L"d3d12.dll");
    IMAGE_DOS_HEADER *dos = (void *)module;
    IMAGE_NT_HEADERS *nt = (void *)((char *)module + dos->e_lfanew);
    printf("d3d12 image size=%lu timestamp=%lu\n", (unsigned long)nt->OptionalHeader.SizeOfImage,
        (unsigned long)nt->FileHeader.TimeDateStamp);
    printf("D3D12CreateDevice=00000000\n"); fflush(stdout);
    IDXGIFactory4 *factory = NULL;
    CHECK(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory));
    ID3D12CommandQueue *queue = NULL;
    D3D12_COMMAND_QUEUE_DESC queue_desc = {.Type = D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue));
    DXGI_SWAP_CHAIN_DESC1 swap_desc = {.Width = 800, .Height = 500, .Format = DXGI_FORMAT_R8G8B8A8_UNORM,
        .SampleDesc = {.Count = 1}, .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT, .BufferCount = 2,
        .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD};
    IDXGISwapChain1 *swap1 = NULL;
    CHECK(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &swap_desc, NULL, NULL, &swap1));
    IDXGISwapChain3 *swap = NULL;
    CHECK(IDXGISwapChain1_QueryInterface(swap1, &IID_IDXGISwapChain3, (void **)&swap));
    ID3D12DescriptorHeap *heap = NULL;
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 2};
    CHECK(ID3D12Device_CreateDescriptorHeap(device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&heap));
    D3D12_CPU_DESCRIPTOR_HANDLE handles[2];
    handles[0] = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    handles[1].ptr = handles[0].ptr + ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    ID3D12Resource *buffers[2];
    for (UINT i = 0; i < 2; ++i) {
        CHECK(IDXGISwapChain3_GetBuffer(swap, i, &IID_ID3D12Resource, (void **)&buffers[i]));
        ID3D12Device_CreateRenderTargetView(device, buffers[i], NULL, handles[i]);
    }
    ID3D12Resource *readback = NULL;
    D3D12_RESOURCE_DESC texture_desc = ID3D12Resource_GetDesc(buffers[0]);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT64 bytes;
    ID3D12Device_GetCopyableFootprints(device, &texture_desc, 0, 1, 0, &footprint, NULL, NULL, &bytes);
    D3D12_HEAP_PROPERTIES readback_heap = {.Type = D3D12_HEAP_TYPE_READBACK};
    D3D12_RESOURCE_DESC readback_desc = {.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER, .Width = bytes,
        .Height = 1, .DepthOrArraySize = 1, .MipLevels = 1, .SampleDesc = {.Count = 1}, .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR};
    CHECK(ID3D12Device_CreateCommittedResource(device, &readback_heap, D3D12_HEAP_FLAG_NONE, &readback_desc,
        D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback));
    ID3D12CommandAllocator *allocator = NULL;
    CHECK(ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator));
    ID3D12GraphicsCommandList *list = NULL;
    CHECK(ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list));
    CHECK(ID3D12GraphicsCommandList_Close(list));
    ID3D12Fence *fence = NULL;
    CHECK(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    ShowWindow(window, SW_SHOW);
    UINT64 frame = 0;
    ULONGLONG started = GetTickCount64();
    while (GetTickCount64() - started < 120000) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) goto done;
            TranslateMessage(&message); DispatchMessageW(&message);
        }
        UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(swap);
        CHECK(ID3D12CommandAllocator_Reset(allocator));
        CHECK(ID3D12GraphicsCommandList_Reset(list, allocator, NULL));
        D3D12_RESOURCE_BARRIER barrier = {.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
            .Transition = {.pResource = buffers[index], .Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .StateBefore = D3D12_RESOURCE_STATE_PRESENT, .StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET}};
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
        const float background[4] = {0.035f, 0.09f, 0.18f, 1};
        const float orange[4] = {1, 0.46f, 0.15f, 1};
        const float cream[4] = {0.95f, 0.94f, 0.87f, 1};
        D3D12_RECT rect = {110, 100, 360, 400};
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, handles[index], background, 0, NULL);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, handles[index], orange, 1, &rect);
        rect = (D3D12_RECT){400, 100, 690, 235};
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, handles[index], cream, 1, &rect);
        rect = (D3D12_RECT){400, 265, 690, 400};
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, handles[index], cream, 1, &rect);
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
        if (frame == 0) {
            D3D12_TEXTURE_COPY_LOCATION source = {.pResource = buffers[index], .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
            D3D12_TEXTURE_COPY_LOCATION destination = {.pResource = readback, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
                .PlacedFootprint = footprint};
            ID3D12GraphicsCommandList_CopyTextureRegion(list, &destination, 0, 0, 0, &source, NULL);
        }
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
        CHECK(ID3D12GraphicsCommandList_Close(list));
        ID3D12CommandList *commands[] = {(ID3D12CommandList *)list};
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, commands);
        CHECK(IDXGISwapChain3_Present(swap, 1, 0));
        CHECK(ID3D12CommandQueue_Signal(queue, fence, ++frame));
        CHECK(ID3D12Fence_SetEventOnCompletion(fence, frame, event));
        if (WaitForSingleObject(event, 5000) != WAIT_OBJECT_0) return 2;
        if (frame == 1) {
            unsigned char *pixels;
            CHECK(ID3D12Resource_Map(readback, 0, NULL, (void **)&pixels));
            unsigned char *orange_pixel = pixels + 150 * footprint.Footprint.RowPitch + 150 * 4;
            if (orange_pixel[0] != 255 || orange_pixel[1] < 115 || orange_pixel[1] > 119 || orange_pixel[2] < 36 || orange_pixel[2] > 40) {
                printf("GPU readback pixel mismatch\n"); return 3;
            }
            if (argc > 1) {
                FILE *file = fopen(argv[1], "wb");
                if (!file) return 4;
                BITMAPFILEHEADER header = {.bfType = 0x4d42, .bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER),
                    .bfSize = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER) + 800 * 500 * 4};
                BITMAPINFOHEADER info = {.biSize = sizeof(BITMAPINFOHEADER), .biWidth = 800, .biHeight = -500,
                    .biPlanes = 1, .biBitCount = 32, .biCompression = BI_RGB, .biSizeImage = 800 * 500 * 4};
                fwrite(&header, sizeof(header), 1, file); fwrite(&info, sizeof(info), 1, file);
                for (UINT y = 0; y < 500; ++y) {
                    unsigned char row[800 * 4];
                    for (UINT x = 0; x < 800; ++x) {
                        const unsigned char *pixel = pixels + y * footprint.Footprint.RowPitch + x * 4;
                        row[x * 4] = pixel[2]; row[x * 4 + 1] = pixel[1]; row[x * 4 + 2] = pixel[0]; row[x * 4 + 3] = 255;
                    }
                    fwrite(row, sizeof(row), 1, file);
                }
                fclose(file);
            }
            ID3D12Resource_Unmap(readback, 0, NULL);
            printf("ClearRenderTargetView + Present + GPU fence + pixel readback=success\n"); fflush(stdout);
            if (argc > 2) break; // Optional capture-only mode for the offline regression.
        }
    }
done:
    printf("Completed frames=%llu\n", (unsigned long long)frame); fflush(stdout);
    CloseHandle(event);
    DestroyWindow(window);
    return 0;
}
