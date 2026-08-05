// SPDX-License-Identifier: MIT
// Vulkan (panvk) version of tiny_interp_probe: varying-interpolation
// precision probe with NO gallium, NO u_blitter, NO GL state tracker.
//
// One triangle covers a WIDTH x 1 R32_UINT render target via dynamic
// rendering. The vertex shader emits a varying v that must interpolate to
// x + 0.5 at the center of pixel x; the fragment shader stores
// floatBitsToUint(v). Readback is vkCmdCopyImageToBuffer into host-visible
// memory (raw bits, no format conversion). CPU checks floor(v) == x.
//
// Modes: "varying" (the test) and "fragcoord" (control: gl_FragCoord.x
// through the identical pipeline). The optional "depth-bias" workaround
// enables Vulkan depth bias with constant, clamp, and slope factors all zero.
//
// Device selection by substring of VkPhysicalDeviceProperties::deviceName
// (default "Mali"); pass "llvmpipe" for a same-binary software control.
//
// Build from this directory:
//   glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
//   glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
//   glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
//   cc -O2 -o vk_interp_probe vk_interp_probe.c -lvulkan -lm
// Run:
//   ./vk_interp_probe [width] [varying|fragcoord] [device-substring]
//                     [baseline|depth-bias]
//
// Exit 0 = all pixels satisfy floor(v) == x, 2 = mismatches, 1 = setup error.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define VK(x)                                                                  \
   do {                                                                        \
      VkResult r_ = (x);                                                       \
      if (r_ != VK_SUCCESS) {                                                  \
         fprintf(stderr, "%s failed at line %d: %d\n", #x, __LINE__, r_);      \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

static VkShaderModule
load_spv(VkDevice dev, const char *path)
{
   FILE *f = fopen(path, "rb");
   if (!f) {
      fprintf(stderr, "cannot open %s (run glslc first)\n", path);
      exit(1);
   }
   fseek(f, 0, SEEK_END);
   long sz = ftell(f);
   fseek(f, 0, SEEK_SET);
   uint32_t *words = malloc(sz);
   if (fread(words, 1, sz, f) != (size_t)sz)
      exit(1);
   fclose(f);

   VkShaderModuleCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = (size_t)sz,
      .pCode = words,
   };
   VkShaderModule mod;
   VK(vkCreateShaderModule(dev, &ci, NULL, &mod));
   free(words);
   return mod;
}

static uint32_t
find_mem_type(VkPhysicalDevice pdev, uint32_t type_bits, VkMemoryPropertyFlags req)
{
   VkPhysicalDeviceMemoryProperties props;
   vkGetPhysicalDeviceMemoryProperties(pdev, &props);
   for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
      if ((type_bits & (1u << i)) &&
          (props.memoryTypes[i].propertyFlags & req) == req)
         return i;
   }
   fprintf(stderr, "no memory type for bits 0x%x req 0x%x\n", type_bits, req);
   exit(1);
}

int
main(int argc, char **argv)
{
   int width = 12288;
   const char *mode = "varying";
   const char *want_dev = "Mali";
   const char *workaround = "baseline";

   if (argc > 5) {
      fprintf(stderr, "usage: %s [width] [varying|fragcoord] [device] "
                      "[baseline|depth-bias]\n", argv[0]);
      return 1;
   }

   if (argc > 1) {
      char *end;
      long w = strtol(argv[1], &end, 10);
      if (*argv[1] == '\0' || *end != '\0' || w < 1 || w > (1 << 23)) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] [device] "
                         "[baseline|depth-bias]\n", argv[0]);
         return 1;
      }
      width = (int)w;
   }
   if (argc > 2) {
      mode = argv[2];
      if (strcmp(mode, "varying") != 0 && strcmp(mode, "fragcoord") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] [device] "
                         "[baseline|depth-bias]\n", argv[0]);
         return 1;
      }
   }
   if (argc > 3)
      want_dev = argv[3];
   if (argc > 4) {
      workaround = argv[4];
      if (strcmp(workaround, "baseline") != 0 &&
          strcmp(workaround, "depth-bias") != 0) {
         fprintf(stderr, "usage: %s [width] [varying|fragcoord] [device] "
                         "[baseline|depth-bias]\n", argv[0]);
         return 1;
      }
   }
   int use_fragcoord = strcmp(mode, "fragcoord") == 0;
   int use_depth_bias = strcmp(workaround, "depth-bias") == 0;

   /* Instance */
   VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "vk_interp_probe",
      .apiVersion = VK_API_VERSION_1_3,
   };
   VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   VK(vkCreateInstance(&ici, NULL, &inst));

   /* Physical device by name substring */
   uint32_t ndev = 0;
   VK(vkEnumeratePhysicalDevices(inst, &ndev, NULL));
   if (!ndev) {
      fprintf(stderr, "no Vulkan devices\n");
      return 1;
   }
   VkPhysicalDevice *pdevs = malloc(ndev * sizeof(*pdevs));
   VK(vkEnumeratePhysicalDevices(inst, &ndev, pdevs));
   VkPhysicalDevice pdev = VK_NULL_HANDLE;
   VkPhysicalDeviceProperties pprops;
   for (uint32_t i = 0; i < ndev; i++) {
      vkGetPhysicalDeviceProperties(pdevs[i], &pprops);
      if (strstr(pprops.deviceName, want_dev)) {
         pdev = pdevs[i];
         break;
      }
   }
   if (pdev == VK_NULL_HANDLE) {
      fprintf(stderr, "no device matching '%s'; available:\n", want_dev);
      for (uint32_t i = 0; i < ndev; i++) {
         vkGetPhysicalDeviceProperties(pdevs[i], &pprops);
         fprintf(stderr, "  %s\n", pprops.deviceName);
      }
      return 1;
   }
   vkGetPhysicalDeviceProperties(pdev, &pprops);
   fprintf(stderr, "device=%s apiVersion=%u.%u.%u driverVersion=0x%x\n",
           pprops.deviceName, VK_API_VERSION_MAJOR(pprops.apiVersion),
           VK_API_VERSION_MINOR(pprops.apiVersion),
           VK_API_VERSION_PATCH(pprops.apiVersion), pprops.driverVersion);

   if ((uint32_t)width > pprops.limits.maxImageDimension2D) {
      fprintf(stderr, "width %d exceeds maxImageDimension2D %u\n", width,
              pprops.limits.maxImageDimension2D);
      return 1;
   }

   /* Queue family with graphics */
   uint32_t nqf = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nqf, NULL);
   VkQueueFamilyProperties *qf = malloc(nqf * sizeof(*qf));
   vkGetPhysicalDeviceQueueFamilyProperties(pdev, &nqf, qf);
   uint32_t qfi = UINT32_MAX;
   for (uint32_t i = 0; i < nqf; i++) {
      if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
         qfi = i;
         break;
      }
   }
   if (qfi == UINT32_MAX) {
      fprintf(stderr, "no graphics queue\n");
      return 1;
   }

   /* Device with dynamic rendering (core 1.3) */
   float prio = 1.0f;
   VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = qfi,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkPhysicalDeviceVulkan13Features feat13 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .dynamicRendering = VK_TRUE,
      .synchronization2 = VK_TRUE,
   };
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &feat13,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
   };
   VkDevice dev;
   VK(vkCreateDevice(pdev, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, qfi, 0, &queue);

   /* Render target: R32_UINT width x 1 */
   VkImageCreateInfo imgci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R32_UINT,
      .extent = {(uint32_t)width, 1, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
               VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
   };
   VkImage img;
   VK(vkCreateImage(dev, &imgci, NULL, &img));
   VkMemoryRequirements imr;
   vkGetImageMemoryRequirements(dev, img, &imr);
   VkMemoryAllocateInfo imai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = imr.size,
      .memoryTypeIndex = find_mem_type(pdev, imr.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
   };
   VkDeviceMemory imem;
   VK(vkAllocateMemory(dev, &imai, NULL, &imem));
   VK(vkBindImageMemory(dev, img, imem, 0));

   VkImageViewCreateInfo ivci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R32_UINT,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
   };
   VkImageView view;
   VK(vkCreateImageView(dev, &ivci, NULL, &view));

   /* Readback buffer */
   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = (VkDeviceSize)width * 4,
      .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
   };
   VkBuffer buf;
   VK(vkCreateBuffer(dev, &bci, NULL, &buf));
   VkMemoryRequirements bmr;
   vkGetBufferMemoryRequirements(dev, buf, &bmr);
   VkMemoryAllocateInfo bmai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = bmr.size,
      .memoryTypeIndex =
         find_mem_type(pdev, bmr.memoryTypeBits,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                          VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
   };
   VkDeviceMemory bmem;
   VK(vkAllocateMemory(dev, &bmai, NULL, &bmem));
   VK(vkBindBufferMemory(dev, buf, bmem, 0));

   /* Pipeline */
   VkShaderModule vs = load_spv(dev, "vk_interp_probe.vert.spv");
   VkShaderModule fs = load_spv(dev, use_fragcoord
                                        ? "vk_interp_probe.fragcoord.frag.spv"
                                        : "vk_interp_probe.varying.frag.spv");

   VkPushConstantRange pcr = {
      .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
      .offset = 0,
      .size = 4,
   };
   VkPipelineLayoutCreateInfo plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .pushConstantRangeCount = 1,
      .pPushConstantRanges = &pcr,
   };
   VkPipelineLayout layout;
   VK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

   VkPipelineShaderStageCreateInfo stages[2] = {
      {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_VERTEX_BIT,
         .module = vs,
         .pName = "main",
      },
      {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
         .module = fs,
         .pName = "main",
      },
   };
   VkPipelineVertexInputStateCreateInfo vin = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
   };
   VkPipelineInputAssemblyStateCreateInfo ia = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
   };
   VkViewport vp = {0.0f, 0.0f, (float)width, 1.0f, 0.0f, 1.0f};
   VkRect2D sc = {{0, 0}, {(uint32_t)width, 1}};
   VkPipelineViewportStateCreateInfo vps = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .pViewports = &vp,
      .scissorCount = 1,
      .pScissors = &sc,
   };
   VkPipelineRasterizationStateCreateInfo rs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL,
      .cullMode = VK_CULL_MODE_NONE,
      .depthBiasEnable = use_depth_bias ? VK_TRUE : VK_FALSE,
      .depthBiasConstantFactor = 0.0f,
      .depthBiasClamp = 0.0f,
      .depthBiasSlopeFactor = 0.0f,
      .lineWidth = 1.0f,
   };
   VkPipelineMultisampleStateCreateInfo ms = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
   };
   VkPipelineColorBlendAttachmentState cba = {
      .blendEnable = VK_FALSE,
      .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                        VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
   };
   VkPipelineColorBlendStateCreateInfo cb = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &cba,
   };
   VkFormat cfmt = VK_FORMAT_R32_UINT;
   VkPipelineRenderingCreateInfo prci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
      .colorAttachmentCount = 1,
      .pColorAttachmentFormats = &cfmt,
   };
   VkGraphicsPipelineCreateInfo gpci = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .pNext = &prci,
      .stageCount = 2,
      .pStages = stages,
      .pVertexInputState = &vin,
      .pInputAssemblyState = &ia,
      .pViewportState = &vps,
      .pRasterizationState = &rs,
      .pMultisampleState = &ms,
      .pColorBlendState = &cb,
      .layout = layout,
   };
   VkPipeline pipe;
   VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

   /* Commands */
   VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = qfi,
   };
   VkCommandPool pool;
   VK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   VkCommandBufferAllocateInfo cbai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer cmd;
   VK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

   VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   VK(vkBeginCommandBuffer(cmd, &begin));

   VkImageMemoryBarrier to_rt = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = 0,
      .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = img,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0,
                        NULL, 0, NULL, 1, &to_rt);

   VkRenderingAttachmentInfo att = {
      .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
      .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
      .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      .clearValue = {.color = {.uint32 = {0xdeadbeef, 0, 0, 0}}},
   };
   VkRenderingInfo ri = {
      .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
      .renderArea = {{0, 0}, {(uint32_t)width, 1}},
      .layerCount = 1,
      .colorAttachmentCount = 1,
      .pColorAttachments = &att,
   };
   vkCmdBeginRendering(cmd, &ri);
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
   float fwidth = (float)width;
   vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &fwidth);
   vkCmdDraw(cmd, 3, 1, 0, 0);
   vkCmdEndRendering(cmd);

   VkImageMemoryBarrier to_src = to_rt;
   to_src.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
   to_src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
   to_src.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
   to_src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1,
                        &to_src);

   VkBufferImageCopy region = {
      .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .imageExtent = {(uint32_t)width, 1, 1},
   };
   vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf,
                          1, &region);

   VkMemoryBarrier host_rd = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host_rd, 0, NULL, 0,
                        NULL);
   VK(vkEndCommandBuffer(cmd));

   VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
   VkFence fence;
   VK(vkCreateFence(dev, &fci, NULL, &fence));
   VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   VK(vkQueueSubmit(queue, 1, &si, fence));
   VK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));

   /* Verify */
   uint32_t *bits;
   VK(vkMapMemory(dev, bmem, 0, (VkDeviceSize)width * 4, 0, (void **)&bits));

   long bad = 0;
   int first_bad = -1;
   long unwritten = 0;
   for (int x = 0; x < width; x++) {
      if (bits[x] == 0xdeadbeef)
         unwritten++;
      float v;
      memcpy(&v, &bits[x], sizeof(v));
      if ((long)floorf(v) != x) {
         if (first_bad < 0)
            first_bad = x;
         bad++;
      }
   }

   float last;
   memcpy(&last, &bits[width - 1], sizeof(last));
   double ideal = (double)width - 0.5;
   double rel_err = (ideal - (double)last) / ideal;

   printf("mode=%s workaround=%s width=%d device=%s: "
          "floor(v) != x at %ld of %d pixels "
          "(first at x=%d, unwritten=%ld)\n",
          mode, workaround, width, pprops.deviceName, bad, width, first_bad,
          unwritten);
   printf("last pixel x=%d: v=%.4f expected=%.1f relative_error=%.3e "
          "(%.3f * 2^-10)\n",
          width - 1, last, ideal, rel_err, rel_err * 1024.0);

   return bad ? 2 : 0;
}
