/*****************************************************************************
 * bonjour.m: mDNS services discovery module based on Bonjour
 *****************************************************************************
 * Copyright (C) 2016 VLC authors, VideoLAN and VideoLabs
 *
 * Authors: Felix Paul Kühne <fkuehne@videolan.org>
 *          Marvin Scholz <epirat07@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_modules.h>
#include <vlc_services_discovery.h>
#include <vlc_renderer_discovery.h>

#import <Foundation/Foundation.h>

#pragma mark Function declarations

static int OpenSD( vlc_object_t * );
static void CloseSD( vlc_object_t * );

static int OpenRD( vlc_object_t * );
static void CloseRD( vlc_object_t * );

VLC_SD_PROBE_HELPER( "Bonjour", N_("Bonjour Network Discovery"), SD_CAT_LAN )
VLC_RD_PROBE_HELPER( "Bonjour_renderer", "Bonjour Renderer Discovery" )

struct services_discovery_sys_t
{
    CFTypeRef _Nullable discoveryController;
};

struct vlc_renderer_discovery_sys
{
    CFTypeRef _Nullable discoveryController;
};

/*
 * Module descriptor
 */
vlc_module_begin()
    set_shortname( "Bonjour" )
    set_description( N_( "Bonjour Network Discovery" ) )
    set_category( CAT_PLAYLIST )
    set_subcategory( SUBCAT_PLAYLIST_SD )
    set_capability( "services_discovery", 0 )
    set_callbacks( OpenSD, CloseSD )
    add_shortcut( "mdns", "bonjour" )
    VLC_SD_PROBE_SUBMODULE
    add_submodule() \
        set_description( N_( "Bonjour Renderer Discovery" ) )
        set_category( CAT_SOUT )
        set_subcategory( SUBCAT_SOUT_RENDERER )
        set_capability( "renderer_discovery", 0 )
        set_callbacks( OpenRD, CloseRD )
        add_shortcut( "mdns_renderer", "bonjour_renderer" )
        VLC_RD_PROBE_SUBMODULE
vlc_module_end()

NSString *const VLCBonjourProtocolName          = @"VLCBonjourProtocolName";
NSString *const VLCBonjourProtocolServiceName   = @"VLCBonjourProtocolServiceName";
NSString *const VLCBonjourIsRenderer            = @"VLCBonjourIsRenderer";
NSString *const VLCBonjourRendererFlags         = @"VLCBonjourRendererFlags";
NSString *const VLCBonjourRendererDemux         = @"VLCBonjourRendererDemux";

#pragma mark -
#pragma mark Interface definition
@interface VLCNetServiceDiscoveryController : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
{
    /* Stores all used service browsers, one for each protocol, usually */
    NSArray *_serviceBrowsers;

    /* Holds a required reference to all NSNetServices */
    NSMutableArray *_rawNetServices;

    /* Holds all successfully resolved NSNetServices */
    NSMutableArray *_resolvedNetServices;

    /* Holds the respective pointers to a vlc_object for each resolved and added NSNetService */
    NSMutableArray *_inputItemsForNetServices;

    /* Stores all protocols that are currently discovered */
    NSArray *_activeProtocols;
}

@property (readonly) BOOL isRendererDiscovery;
@property (readonly, nonatomic) vlc_object_t *p_this;

- (instancetype)initWithRendererDiscoveryObject:(vlc_renderer_discovery_t *)p_rd;
- (instancetype)initWithServicesDiscoveryObject:(services_discovery_t *)p_sd;

- (void)startDiscovery;
- (void)stopDiscovery;

@end

@implementation VLCNetServiceDiscoveryController

- (instancetype)initWithRendererDiscoveryObject:(vlc_renderer_discovery_t *)p_rd
{
    self = [super init];
    if (self) {
        _p_this = VLC_OBJECT( p_rd );
        _isRendererDiscovery = YES;
    }

    return self;
}

- (instancetype)initWithServicesDiscoveryObject:(services_discovery_t *)p_sd
{
    self = [super init];
    if (self) {
        _p_this = VLC_OBJECT( p_sd );
        _isRendererDiscovery = NO;
    }

    return self;
}

- (void)startDiscovery
{
    NSDictionary *VLCFtpProtocol = @{ VLCBonjourProtocolName        : @"ftp",
                                      VLCBonjourProtocolServiceName : @"_ftp._tcp.",
                                      VLCBonjourIsRenderer          : @(NO)
                                      };
    NSDictionary *VLCSmbProtocol = @{ VLCBonjourProtocolName        : @"smb",
                                      VLCBonjourProtocolServiceName : @"_smb._tcp.",
                                      VLCBonjourIsRenderer          : @(NO)
                                      };
    NSDictionary *VLCNfsProtocol = @{ VLCBonjourProtocolName        : @"nfs",
                                      VLCBonjourProtocolServiceName : @"_nfs._tcp.",
                                      VLCBonjourIsRenderer          : @(NO)
                                      };
    NSDictionary *VLCSftpProtocol = @{ VLCBonjourProtocolName       : @"sftp",
                                       VLCBonjourProtocolServiceName: @"_sftp-ssh._tcp.",
                                       VLCBonjourIsRenderer         : @(NO)
                                       };
    NSDictionary *VLCCastProtocol = @{ VLCBonjourProtocolName       : @"chromecast",
                                       VLCBonjourProtocolServiceName: @"_googlecast._tcp.",
                                       VLCBonjourIsRenderer         : @(YES),
                                       VLCBonjourRendererFlags      : @(VLC_RENDERER_CAN_AUDIO),
                                       VLCBonjourRendererDemux      : @"cc_demux"
                                       };

    NSArray *VLCSupportedProtocols = @[VLCFtpProtocol,
                                      VLCSmbProtocol,
                                      VLCNfsProtocol,
                                      VLCSftpProtocol,
                                      VLCCastProtocol];

    _rawNetServices = [[NSMutableArray alloc] init];
    _resolvedNetServices = [[NSMutableArray alloc] init];
    _inputItemsForNetServices = [[NSMutableArray alloc] init];

    NSMutableArray *discoverers = [[NSMutableArray alloc] init];
    NSMutableArray *protocols = [[NSMutableArray alloc] init];

    msg_Info(_p_this, "starting discovery");
    for (NSDictionary *protocol in VLCSupportedProtocols) {
        msg_Info(_p_this, "looking up %s", [protocol[VLCBonjourProtocolName] UTF8String]);

        /* Only discover services if we actually have a module that can handle those */
        if (!module_exists([protocol[VLCBonjourProtocolName] UTF8String]) && !_isRendererDiscovery) {
            msg_Info(_p_this, "no module for %s, skipping", [protocol[VLCBonjourProtocolName] UTF8String]);
            continue;
        }

        /* Only discover hosts it they match the current mode (renderer or service) */
        if ([protocol[VLCBonjourIsRenderer] boolValue] != _isRendererDiscovery) {
            msg_Info(_p_this, "%s does not match current discovery mode, skipping", [protocol[VLCBonjourProtocolName] UTF8String]);
            continue;
        }

        NSNetServiceBrowser *serviceBrowser = [[NSNetServiceBrowser alloc] init];
        [serviceBrowser setDelegate:self];
        msg_Info(_p_this, "starting discovery for type %s", [protocol[VLCBonjourProtocolServiceName] UTF8String]);
        [serviceBrowser searchForServicesOfType:protocol[VLCBonjourProtocolServiceName] inDomain:@"local."];
        [discoverers addObject:serviceBrowser];
        [protocols addObject:protocol];
    }

    _serviceBrowsers = [discoverers copy];
    _activeProtocols = [protocols copy];
}

- (void)stopDiscovery
{
    [_serviceBrowsers makeObjectsPerformSelector:@selector(stop)];

    for (NSValue *item in _inputItemsForNetServices) {
        if (_isRendererDiscovery) {
            [self removeRawRendererItem:item];
        } else {
            [self removeRawInputItem:item];
        }
    }

    [_inputItemsForNetServices removeAllObjects];
    [_resolvedNetServices removeAllObjects];
    msg_Info(_p_this, "stopped discovery");
}

#pragma mark - 
#pragma mark Delegate methods

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didFindService:(NSNetService *)aNetService moreComing:(BOOL)moreComing
{
    msg_Info(_p_this, "found something, looking up");
    msg_Dbg(self.p_this, "found bonjour service: %s (%s)", [aNetService.name UTF8String], [aNetService.type UTF8String]);
    [_rawNetServices addObject:aNetService];
    aNetService.delegate = self;
    [aNetService resolveWithTimeout:5.];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didRemoveService:(NSNetService *)aNetService moreComing:(BOOL)moreComing
{
    msg_Dbg(self.p_this, "bonjour service disappeared: %s", [aNetService.name UTF8String]);

    /* If the item was not looked-up yet, just remove it */
    if ([_rawNetServices containsObject:aNetService])
        [_rawNetServices removeObject:aNetService];

    /* If the item was already resolved, the associated input or renderer items needs to be removed as well */
    if ([_resolvedNetServices containsObject:aNetService]) {
        NSInteger index = [_resolvedNetServices indexOfObject:aNetService];
        if (index == NSNotFound) {
            return;
        }

        [_resolvedNetServices removeObjectAtIndex:index];

        if (_isRendererDiscovery) {
            [self removeRawRendererItem:_inputItemsForNetServices[index]];
        } else {
            [self removeRawInputItem:_inputItemsForNetServices[index]];
        }

        /* Remove item pointer from our lookup array */
        [_inputItemsForNetServices removeObjectAtIndex:index];
    }
}

- (void)netServiceDidResolveAddress:(NSNetService *)aNetService
{
    msg_Info(_p_this, "resolved something");
    if (![_resolvedNetServices containsObject:aNetService]) {
        NSString *serviceType = aNetService.type;
        NSString *protocol = nil;
        for (NSDictionary *protocolDefinition in _activeProtocols) {
            if ([serviceType isEqualToString:protocolDefinition[VLCBonjourProtocolServiceName]]) {
                protocol = protocolDefinition[VLCBonjourProtocolName];
            }
        }

        if (_isRendererDiscovery) {
            [self addResolvedRendererItem:aNetService withProtocol:protocol];
        } else {
            [self addResolvedInputItem:aNetService withProtocol:protocol];
        }
    }

    [_rawNetServices removeObject:aNetService];
}

- (void)netService:(NSNetService *)aNetService didNotResolve:(NSDictionary *)errorDict
{
    msg_Dbg(_p_this, "failed to resolve: %s", [aNetService.name UTF8String]);
    [_rawNetServices removeObject:aNetService];
}

#pragma mark -
#pragma mark Helper methods

- (void)addResolvedRendererItem:(NSNetService *)netService withProtocol:(NSString *)protocol
{
    vlc_renderer_discovery_t *p_rd = (vlc_renderer_discovery_t *)_p_this;

    NSString *uri = [NSString stringWithFormat:@"%@://%@:%ld", protocol, netService.hostName, netService.port];
    NSDictionary *txtDict = [NSNetService dictionaryFromTXTRecordData:[netService TXTRecordData]];

    // TODO: Detect rendered capabilities and adapt to work with not just chromecast
    vlc_renderer_item_t *p_renderer_item = vlc_renderer_item_new( "chromecast", [netService.name UTF8String],
                                                                 [uri UTF8String], NULL, "cc_demux",
                                                                 "", VLC_RENDERER_CAN_VIDEO );
    if (p_renderer_item != NULL) {
        vlc_rd_add_item( p_rd, p_renderer_item );
        [_inputItemsForNetServices addObject:[NSValue valueWithPointer:p_renderer_item]];
        [_resolvedNetServices addObject:netService];
    }
}

- (void)removeRawRendererItem:(NSValue *)item
{
    vlc_renderer_discovery_t *p_rd = (vlc_renderer_discovery_t *)_p_this;
    vlc_renderer_item_t *input_item = [item pointerValue];

    if (input_item != NULL) {
        vlc_rd_remove_item( p_rd, input_item );
        vlc_renderer_item_release( input_item );
    }
}

- (void)addResolvedInputItem:(NSNetService *)netService withProtocol:(NSString *)protocol
{
    services_discovery_t *p_sd = (services_discovery_t *)_p_this;

    NSString *uri = [NSString stringWithFormat:@"%@://%@:%ld", protocol, netService.hostName, netService.port];
    input_item_t *p_input_item = input_item_NewDirectory([uri UTF8String], [netService.name UTF8String], ITEM_NET );
    if (p_input_item != NULL) {
        services_discovery_AddItem( p_sd, p_input_item, NULL);
        [_inputItemsForNetServices addObject:[NSValue valueWithPointer:p_input_item]];
        [_resolvedNetServices addObject:netService];
    }
}

- (void)removeRawInputItem:(NSValue *)item
{
    services_discovery_t *p_sd = (services_discovery_t *)_p_this;
    input_item_t *input_item = [item pointerValue];

    if (input_item != NULL) {
        services_discovery_RemoveItem( p_sd, input_item );
        input_item_Release( input_item );
    }
}

@end

static int OpenSD(vlc_object_t *p_this)
{
    services_discovery_t *p_sd = (services_discovery_t *)p_this;
    services_discovery_sys_t *p_sys = NULL;

    p_sd->p_sys = p_sys = calloc(1, sizeof(services_discovery_sys_t));
    if (!p_sys) {
        return VLC_ENOMEM;
    }

    p_sd->description = _("Bonjour Network Discovery");

    VLCNetServiceDiscoveryController *discoveryController = [[VLCNetServiceDiscoveryController alloc] initWithServicesDiscoveryObject:p_sd];

    p_sys->discoveryController = CFBridgingRetain(discoveryController);

    [discoveryController startDiscovery];

    return VLC_SUCCESS;
}

static void CloseSD(vlc_object_t *p_this)
{
    services_discovery_t *p_sd = (services_discovery_t *)p_this;
    services_discovery_sys_t *p_sys = p_sd->p_sys;

    VLCNetServiceDiscoveryController *discoveryController = (__bridge VLCNetServiceDiscoveryController *)(p_sys->discoveryController);
    [discoveryController stopDiscovery];

    CFBridgingRelease(p_sys->discoveryController);
    discoveryController = nil;

    free(p_sys);
}

static int OpenRD(vlc_object_t *p_this)
{
    vlc_renderer_discovery_t *p_rd = (vlc_renderer_discovery_t *)p_this;
    vlc_renderer_discovery_sys *p_sys = NULL;

    p_rd->p_sys = p_sys = calloc(1, sizeof(vlc_renderer_discovery_sys));
    if (!p_sys) {
        return VLC_ENOMEM;
    }

    VLCNetServiceDiscoveryController *discoveryController = [[VLCNetServiceDiscoveryController alloc] initWithRendererDiscoveryObject:p_rd];

    p_sys->discoveryController = CFBridgingRetain(discoveryController);

    [discoveryController startDiscovery];

    return VLC_SUCCESS;
}

static void CloseRD(vlc_object_t *p_this)
{
    vlc_renderer_discovery_t *p_rd = (vlc_renderer_discovery_t *)p_this;
    vlc_renderer_discovery_sys *p_sys = p_rd->p_sys;

    VLCNetServiceDiscoveryController *discoveryController = (__bridge VLCNetServiceDiscoveryController *)(p_sys->discoveryController);
    [discoveryController stopDiscovery];

    CFBridgingRelease(p_sys->discoveryController);
    discoveryController = nil;

    free(p_sys);
}
