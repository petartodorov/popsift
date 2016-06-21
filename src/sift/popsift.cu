#include "popsift.h"
#include "s_sigma.h"
#include "gauss_filter.h"
#include "write_plane_2d.h"
#include "sift_extrema_mgmt.h"
#include "c_util_img.h"
#include "sift_pyramid.h"

using namespace std;

PopSift::PopSift( const popart::Config& config )
    : _config( config )
{
    _config.levels = max( 2, config.levels );

    const bool vlfeat_mode = ( config.sift_mode == popart::Config::VLFeat );
    popart::init_filter( _config.sigma,
                         _config.levels,
                         vlfeat_mode,
                         _config.hasInitialBlur(),
                         _config.getInitialBlur(),
                         _config.start_sampling );
    popart::init_sigma(  _config.sigma,
                         _config.levels,
                         _config._threshold,
                         _config._edge_limit );
    popart::init_extrema_limits( 10000 );
}

PopSift::~PopSift()
{ }

bool PopSift::init( int pipe, int w, int h )
{
    cudaEvent_t start, end;
    cudaEventCreate( &start );
    cudaEventCreate( &end );
    cudaDeviceSynchronize();
    cudaEventRecord( start, 0 );

    if( pipe < 0 && pipe >= MAX_PIPES ) {
        return false;
    }

    /* up=-1 -> scale factor=2
     * up= 0 -> scale factor=1
     * up= 1 -> scale factor=0.5
     */
    float scaleFactor = 1.0 / pow( 2.0, _config.start_sampling );

    if( _config.octaves < 0 ) {
        int oct = _config.octaves;
        oct = max(int (floor( logf( (float)min( w, h ) )
                            / logf( 2.0f ) ) - 3.0f + scaleFactor ), 1);
        _config.octaves = oct;
    }

    _pipe[pipe]._inputImage = new popart::Image( w, h );
    _pipe[pipe]._pyramid = new popart::Pyramid( _config,
                                                _pipe[pipe]._inputImage,
                                                // octaves,
                                                // _config.levels,
                                                ceilf( w * scaleFactor ),
                                                ceilf( h * scaleFactor ) );
                                                // _config.scaling_mode );

    cudaDeviceSynchronize();
    cudaEventRecord( end, 0 );
    cudaEventSynchronize( end );
    float elapsedTime;
    cudaEventElapsedTime( &elapsedTime, start, end );

    cerr << "Initialization of pipe " << pipe << " took " << elapsedTime << " ms" << endl;

    return true;
}

void PopSift::uninit( int pipe )
{
    if( pipe < 0 && pipe >= MAX_PIPES ) return;

    delete _pipe[pipe]._inputImage;
    delete _pipe[pipe]._pyramid;
}

void PopSift::execute( int pipe, const imgStream* inpPtr )
{
    const imgStream& inp = *inpPtr;

    if( pipe < 0 && pipe >= MAX_PIPES ) return;

    cudaEvent_t start, end;
    cudaEventCreate( &start );
    cudaEventCreate( &end );
    cudaDeviceSynchronize();
    cudaEventRecord( start, 0 );

    assert( inp.data_g == 0 );
    assert( inp.data_b == 0 );

    _pipe[pipe]._inputImage->load( inp );

    _pipe[pipe]._pyramid->find_extrema( _pipe[pipe]._inputImage );

    int octaves = _pipe[pipe]._pyramid->getNumOctaves();

    cudaDeviceSynchronize();

    for( int o=0; o<octaves; o++ ) {
        _pipe[pipe]._pyramid->download_descriptors( o );
    }

    cudaDeviceSynchronize();
    cudaEventRecord( end, 0 );
    cudaEventSynchronize( end );
    float elapsedTime;
    cudaEventElapsedTime( &elapsedTime, start, end );

    cerr << "Execution of pipe " << pipe << " took " << elapsedTime << " ms" << endl;

    bool log_to_file = ( _config.log_mode == popart::Config::All );
    if( log_to_file ) {
        popart::write_plane2D( "upscaled-input-image.pgm",
                               true, // is stored on device
                               _pipe[pipe]._inputImage->getUpscaledImage() );

        int levels  = _pipe[pipe]._pyramid->getNumLevels();

        for( int o=0; o<octaves; o++ ) {
            for( int s=0; s<levels+3; s++ ) {
                _pipe[pipe]._pyramid->download_and_save_array( "pyramid", o, s );
            }
        }
        for( int o=0; o<octaves; o++ ) {
            _pipe[pipe]._pyramid->save_descriptors( "pyramid", o, _config.start_sampling );
        }
    }
}
