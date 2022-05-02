// Copyright 2022 MetaOPT Team. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ==============================================================================

#include <torch/extension.h>

#include <vector>

#include "adam_op/adam_op_impl.cuh"
#include "utils.h"

namespace TorchOpt {

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamForwardInplaceCUDAKernel(
    const other_t b1, const other_t inv_one_minus_pow_b1, const other_t b2,
    const other_t inv_one_minus_pow_b2, const other_t eps,
    const other_t eps_root, const size_t n, scalar_t *__restrict__ updates_ptr,
    scalar_t *__restrict__ mu_ptr, scalar_t *__restrict__ nu_ptr) {
  unsigned tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }
  const scalar_t updates = updates_ptr[tid];
  const scalar_t mu = mu_ptr[tid];
  const scalar_t nu = nu_ptr[tid];

  const scalar_t mu_out = b1 * mu + (1 - b1) * updates;
  const scalar_t nu_out = b2 * nu + (1 - b2) * updates * updates;
  const scalar_t updates_out =
      mu_out * inv_one_minus_pow_b1 /
      (sqrt(nu_out * inv_one_minus_pow_b2 + eps_root) + eps);

  mu_ptr[tid] = mu_out;
  nu_ptr[tid] = nu_out;
  updates_ptr[tid] = updates_out;
}
}  // namespace

TensorArray<3> adamForwardInplaceCUDA(torch::Tensor &updates, torch::Tensor &mu,
                                      torch::Tensor &nu, const float b1,
                                      const float b2, const float eps,
                                      const float eps_root, const int count) {
  using other_t = float;
  const float inv_one_minus_pow_b1 = 1 / (1 - std::pow(b1, count));
  const float inv_one_minus_pow_b2 = 1 / (1 - std::pow(b2, count));

  const size_t n = getTensorPlainSize(updates);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      updates.scalar_type(), "adamForwardInplaceCUDA", ([&] {
        adamForwardInplaceCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            b1, inv_one_minus_pow_b1, b2, inv_one_minus_pow_b2, eps, eps_root,
            n, updates.data_ptr<scalar_t>(), mu.data_ptr<scalar_t>(),
            nu.data_ptr<scalar_t>());
      }));
  return TensorArray<3>{updates, mu, nu};
}
namespace {
template <typename scalar_t, typename other_t>
__global__ void adamForwardMuCUDAKernel(
    const scalar_t *__restrict__ updates_ptr,
    const scalar_t *__restrict__ mu_ptr, const other_t b1, const size_t n,
    scalar_t *__restrict__ mu_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t updates = updates_ptr[tid];
  const scalar_t mu = mu_ptr[tid];
  const scalar_t mu_out = b1 * mu + (1 - b1) * updates;
  mu_out_ptr[tid] = mu_out;
}
}  // namespace

torch::Tensor adamForwardMuCUDA(const torch::Tensor &updates,
                                const torch::Tensor &mu, const float b1) {
  using other_t = float;

  auto mu_out = torch::empty_like(mu);

  const size_t n = getTensorPlainSize(updates);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      updates.scalar_type(), "adamForwardMuCUDA", ([&] {
        adamForwardMuCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            updates.data_ptr<scalar_t>(), mu.data_ptr<scalar_t>(), b1, n,
            mu_out.data_ptr<scalar_t>());
      }));
  return mu_out;
};

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamForwardNuCUDAKernel(
    const scalar_t *__restrict__ updates_ptr,
    const scalar_t *__restrict__ nu_ptr, const other_t b2, const size_t n,
    scalar_t *__restrict__ nu_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t updates = updates_ptr[tid];
  const scalar_t nu = nu_ptr[tid];

  const scalar_t nu_out = b2 * nu + (1 - b2) * pow(updates, 2);
  nu_out_ptr[tid] = nu_out;
}
}  // namespace

torch::Tensor adamForwardNuCUDA(const torch::Tensor &updates,
                                const torch::Tensor &nu, const float b2) {
  using other_t = float;

  auto nu_out = torch::empty_like(nu);

  const size_t n = getTensorPlainSize(updates);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      updates.scalar_type(), "adamForwardNuCUDA", ([&] {
        adamForwardNuCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            updates.data_ptr<scalar_t>(), nu.data_ptr<scalar_t>(), b2, n,
            nu_out.data_ptr<scalar_t>());
      }));
  return nu_out;
};

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamForwardUpdatesCUDAKernel(
    const scalar_t *__restrict__ new_mu_ptr,
    const scalar_t *__restrict__ new_nu_ptr, const other_t inv_one_minus_pow_b1,
    const other_t inv_one_minus_pow_b2, const other_t eps,
    const other_t eps_root, const size_t n,
    scalar_t *__restrict__ updates_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t new_mu = new_mu_ptr[tid];
  const scalar_t new_nu = new_nu_ptr[tid];
  const scalar_t mu_hat = new_mu * inv_one_minus_pow_b1;
  const scalar_t nu_hat = new_nu * inv_one_minus_pow_b2;
  updates_out_ptr[tid] = mu_hat / (sqrt(nu_hat + eps_root) + eps);
}
}  // namespace

torch::Tensor adamForwardUpdatesCUDA(const torch::Tensor &new_mu,
                                     const torch::Tensor &new_nu,
                                     const float b1, const float b2,
                                     const float eps, const float eps_root,
                                     const int count) {
  using other_t = float;

  auto updates_out = torch::empty_like(new_mu);

  const other_t one_minus_pow_b1 = 1 - std::pow(b1, count);
  const other_t inv_one_minus_pow_b1 = 1 / one_minus_pow_b1;
  const other_t one_minus_pow_b2 = 1 - std::pow(b2, count);
  const other_t inv_one_minus_pow_b2 = 1 / one_minus_pow_b2;

  const size_t n = getTensorPlainSize(new_mu);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      new_mu.scalar_type(), "adamForwardUpdatesCUDA", ([&] {
        adamForwardUpdatesCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            new_mu.data_ptr<scalar_t>(), new_nu.data_ptr<scalar_t>(),
            inv_one_minus_pow_b1, inv_one_minus_pow_b2, eps, eps_root, n,
            updates_out.data_ptr<scalar_t>());
      }));
  return updates_out;
};

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamBackwardMuCUDAKernel(
    const scalar_t *__restrict__ dmu_ptr, const other_t b1, const size_t n,
    scalar_t *__restrict__ dupdates_out_ptr,
    scalar_t *__restrict__ dmu_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t dmu = dmu_ptr[tid];

  dupdates_out_ptr[tid] = (1 - b1) * dmu;
  dmu_out_ptr[tid] = b1 * dmu;
}
}  // namespace

TensorArray<2> adamBackwardMuCUDA(const torch::Tensor &dmu,
                                  const torch::Tensor &updates,
                                  const torch::Tensor &mu, const float b1) {
  using other_t = float;

  auto dupdates_out = torch::empty_like(updates);
  auto dmu_out = torch::empty_like(mu);

  const size_t n = getTensorPlainSize(dmu);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      dmu.scalar_type(), "adamBackwardMuCUDA", ([&] {
        adamBackwardMuCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            dmu.data_ptr<scalar_t>(), b1, n, dupdates_out.data_ptr<scalar_t>(),
            dmu_out.data_ptr<scalar_t>());
      }));
  return TensorArray<2>{std::move(dupdates_out), std::move(dmu_out)};
};

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamBackwardNuCUDAKernel(
    const scalar_t *__restrict__ dnu_ptr,
    const scalar_t *__restrict__ updates_ptr, const other_t b2, const size_t n,
    scalar_t *__restrict__ dupdates_out_ptr,
    scalar_t *__restrict__ dnu_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t dnu = dnu_ptr[tid];
  const scalar_t updates = updates_ptr[tid];

  dupdates_out_ptr[tid] = 2 * (1 - b2) * updates * dnu;
  dnu_out_ptr[tid] = b2 * dnu;
}
}  // namespace

TensorArray<2> adamBackwardNuCUDA(const torch::Tensor &dnu,
                                  const torch::Tensor &updates,
                                  const torch::Tensor &nu, const float b2) {
  using other_t = float;

  auto dupdates_out = torch::empty_like(updates);
  auto dnu_out = torch::empty_like(nu);

  const size_t n = getTensorPlainSize(dnu);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      dnu.scalar_type(), "adamForwardNuCUDA", ([&] {
        adamBackwardNuCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            dnu.data_ptr<scalar_t>(), updates.data_ptr<scalar_t>(), b2, n,
            dupdates_out.data_ptr<scalar_t>(), dnu_out.data_ptr<scalar_t>());
      }));
  return TensorArray<2>{std::move(dupdates_out), std::move(dnu_out)};
};

namespace {
template <typename scalar_t, typename other_t>
__global__ void adamBackwardUpdatesCUDAKernel(
    const scalar_t *__restrict__ dupdates_ptr,
    const scalar_t *__restrict__ updates_ptr,
    const scalar_t *__restrict__ new_mu_ptr, const other_t one_minus_pow_b1,
    const other_t inv_one_minus_pow_b2, const size_t n,
    scalar_t *__restrict__ dnew_mu_out_ptr,
    scalar_t *__restrict__ dnew_nu_out_ptr) {
  size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid >= n) {
    return;
  }

  const scalar_t dupdates = dupdates_ptr[tid];
  const scalar_t updates = updates_ptr[tid];
  const scalar_t new_mu = new_mu_ptr[tid];

  if (new_mu == 0) {
    dnew_mu_out_ptr[tid] = 0;
    dnew_nu_out_ptr[tid] = 0;
    return;
  }

  const scalar_t updates_div_new_mu = updates / new_mu;

  const scalar_t denominator = updates_div_new_mu * one_minus_pow_b1;

  dnew_mu_out_ptr[tid] = dupdates * updates_div_new_mu;
  dnew_nu_out_ptr[tid] = -dupdates * updates * denominator * 0.5 *
                         inv_one_minus_pow_b2 * denominator;
}
}  // namespace

TensorArray<2> adamBackwardUpdatesCUDA(const torch::Tensor &dupdates,
                                       const torch::Tensor &updates,
                                       const torch::Tensor &new_mu,
                                       const torch::Tensor &new_nu,
                                       const float b1, const float b2,
                                       const int count) {
  using other_t = float;

  auto dmu_out = torch::empty_like(new_mu);
  auto dnu_out = torch::empty_like(new_nu);

  const other_t one_minus_pow_b1 = 1 - std::pow(b1, count);
  const other_t one_minus_pow_b2 = 1 - std::pow(b2, count);
  const other_t inv_one_minus_pow_b2 = 1 / one_minus_pow_b2;

  const size_t n = getTensorPlainSize(dupdates);
  const dim3 block(std::min(n, size_t(256)));
  const dim3 grid((n - 1) / block.x + 1);
  AT_DISPATCH_FLOATING_TYPES(
      dupdates.scalar_type(), "adamBackwardUpdatesCUDA", ([&] {
        adamBackwardUpdatesCUDAKernel<scalar_t, other_t><<<grid, block>>>(
            dupdates.data_ptr<scalar_t>(), updates.data_ptr<scalar_t>(),
            new_mu.data_ptr<scalar_t>(), one_minus_pow_b1, inv_one_minus_pow_b2,
            n, dmu_out.data_ptr<scalar_t>(), dnu_out.data_ptr<scalar_t>());
      }));
  return TensorArray<2>{std::move(dmu_out), std::move(dnu_out)};
};
}  // namespace TorchOpt