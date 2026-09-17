#include "workflow.hpp"
#include <htslib/tbx.h>
#include <iostream>
#include <memory>
#include <stdexcept>
// Inspect only an index: no network or genotype decoding here.
int main(){try{
    auto a=pg::arguments();if(a.size()!=3)throw std::runtime_error("Usage: region-ranges.exe index.tbi region");
    std::unique_ptr<tbx_t,decltype(&tbx_destroy)> index(tbx_index_load2("unused.vcf.gz",a[1].c_str()),&tbx_destroy);
    if(!index)throw std::runtime_error("Cannot read tabix index");
    std::unique_ptr<hts_itr_t,decltype(&hts_itr_destroy)> it(tbx_itr_querys(index.get(),a[2].c_str()),&hts_itr_destroy);
    if(!it||it->n_off<1)throw std::runtime_error("No indexed chunks for region");
    pg::json ranges=pg::json::array();
    for(int i=0;i<it->n_off;++i)ranges.push_back({{"start",it->off[i].u>>16},{"end",(it->off[i].v>>16)+65535}});
    std::cout<<ranges.dump(2)<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
