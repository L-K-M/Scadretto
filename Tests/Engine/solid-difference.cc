// Compare closed triangulated OFF meshes with the verification pin's Manifold.
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>

#include <manifold/manifold.h>

namespace {

manifold::Manifold readSolid(const char *path)
{
  std::ifstream input(path);
  std::string header;
  std::size_t vertices = 0, triangles = 0, edges = 0;
  if (!(input >> header >> vertices >> triangles >> edges) || header != "OFF" ||
      vertices == 0 || vertices > 1'000'000 || triangles == 0 || triangles > 2'000'000) {
    throw std::runtime_error(std::string("Invalid OFF header: ") + path);
  }

  manifold::MeshGL64 mesh;
  mesh.numProp = 3;
  mesh.vertProperties.resize(vertices * 3);
  for (auto& value : mesh.vertProperties) {
    if (!(input >> value) || !std::isfinite(value)) throw std::runtime_error("Invalid coordinate");
  }
  mesh.triVerts.reserve(triangles * 3);
  for (std::size_t face = 0; face < triangles; ++face) {
    unsigned corners = 0;
    if (!(input >> corners) || corners != 3) throw std::runtime_error("Expected a triangle");
    for (unsigned corner = 0; corner < corners; ++corner) {
      std::uint64_t index = 0;
      if (!(input >> index) || index >= vertices) throw std::runtime_error("Invalid index");
      mesh.triVerts.push_back(index);
    }
  }

  manifold::Manifold solid(mesh);
  const auto volume = solid.Volume();
  if (solid.Status() != manifold::Manifold::Error::NoError || solid.IsEmpty() ||
      !std::isfinite(volume) || volume <= 0 || solid.NumTri() != triangles) {
    throw std::runtime_error(std::string("Input is invalid or changed during conversion: ") + path);
  }
  return solid;
}

double checkedDifferenceVolume(const manifold::Manifold& a, const manifold::Manifold& b)
{
  const auto difference = a - b;
  const auto volume = difference.Volume();
  if (difference.Status() != manifold::Manifold::Error::NoError || !std::isfinite(volume)) {
    throw std::runtime_error("Manifold boolean failed");
  }
  // Near-identical faces can leave slivers whose signed volume rounds below zero.
  return std::abs(volume);
}

}  // namespace

int main(int argc, char **argv)
{
  if (argc != 3) {
    std::cerr << "Usage: solid-difference A.off B.off\n";
    return 2;
  }
  try {
    const auto a = readSolid(argv[1]);
    const auto b = readSolid(argv[2]);
    std::cout << std::setprecision(17)
              << checkedDifferenceVolume(a, b) + checkedDifferenceVolume(b, a) << '\n';
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
