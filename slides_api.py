# Copyright 2024 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Google Slides access.

Contains all the Google Slides methods to create new slides and add
output details and charts to them.
"""

import datetime
import re
import json
import os
import logging
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from flask import session
from fs_storage import get_value_session
from project_secrets import get_secret


def create_slide(
  session_id='',
  slide_id=os.environ.get('SLIDE_TEMPLATE'),
  client_name='',
  prepend=False,
) -> any:
  """Creates a copy of a slide template, replaces the elements
  that are specified then returns the new slide ID to allow
  access to the file.

  Args:
    session_id: The ID of the session.
    slide_id: The ID of the template slide to make a copy of.
    client_name: The name of the client to put into the new slide.
    prepend: Boolean if to keep or remove the appended datasource tags
    in the variables.

  Returns:
    Slide ID for the new copy of the slide.
  """
  logging.info('[SLIDES] create_slide called: session_id=%s slide_id=%s client_name=%s prepend=%s',
               session_id, slide_id, client_name, prepend)

  raw_creds = get_value_session(session['session_id'], 'credentials')
  if raw_creds is None:
    logging.error('[SLIDES] No credentials in Firestore for session_id=%s', session.get('session_id'))
    return '0'
  try:
    creds_info = json.loads(raw_creds)
  except (ValueError, TypeError) as e:
    logging.exception('[SLIDES] Failed to parse credentials: %s', e)
    return '0'

  creds = Credentials.from_authorized_user_info(creds_info)
  slides_service = build('slides', 'v1', credentials=creds)
  drive_service = build('drive', 'v3', credentials=creds)

  body = {'name': f'{client_name} - Causal Impact Insights'}
  try:
    drive_response = (
      drive_service.files().copy(fileId=slide_id, body=body).execute()
    )
    slide_copy_id = drive_response.get('id')
    logging.info('[SLIDES] Template copied successfully: slide_copy_id=%s', slide_copy_id)
  except Exception as e:
    logging.exception('[SLIDES] Failed to copy template slide_id=%s: %s', slide_id, e)
    return '0'

  request_data = get_value_session(session_id, 'output_data')
  if request_data is None:
    logging.error('[SLIDES] output_data not found in Firestore for session_id=%s', session_id)
    return '0'
  logging.info('[SLIDES] output_data loaded: keys=%s', list(request_data.keys()))

  target_event = request_data['target_event']
  covariates = request_data.get('covariates', '')
  if prepend:
    target_event = re.sub(r'^.*?_', '', target_event)
    covariates = ', '.join(
      [re.sub(r'^.*?_', '', cov) for cov in covariates.split(',')]
    )

  to_replace = [
    ['CLIENT_NAME', client_name],
    ['DATE', datetime.date.today().strftime('%d-%m-%Y')],
    ['TARGET_EVENT', str(target_event)],
    ['COVARIATES', str(covariates)],
    ['PREPERIOD-START', request_data['from_date']],
    [
      'PREPERIOD-END',
      (
        datetime.datetime.strptime(request_data['event_date'], '%Y-%m-%d')
        - datetime.timedelta(days=1)
      ).strftime('%Y-%m-%d'),
    ],
    ['POSTPERIOD-START', request_data['event_date']],
    ['POSTPERIOD-END', request_data['to_date']],
    ['P_VALUE', str(request_data.get('p_value', ''))],
    ['INCR_ACTIONS', str(request_data.get('tot_inc', ''))],
    ['RELATIVE_EFFECT', str(request_data.get('rel_eff', ''))],
    ['SUMMARY', str(request_data.get('summary', ''))],
    ['REPORT', str(request_data.get('report', ''))],
  ]
  logging.info('[SLIDES] Replacement pairs built: %s', [(r[0], str(r[1])[:60]) for r in to_replace])

  requests = []
  for label in to_replace:
    requests.append(
      {
        'replaceAllText': {
          'replaceText': label[1],
          'containsText': {'matchCase': False, 'text': f'{{{{{label[0]}}}}}'},
        }
      }
    )

  page_id = ''
  final_element = ''
  try:
    presentation = (
      slides_service.presentations().get(presentationId=slide_copy_id).execute()
    )
  except Exception as e:
    logging.exception('[SLIDES] Failed to get presentation %s: %s', slide_copy_id, e)
    return '0'

  slides = presentation.get('slides', [])
  logging.info('[SLIDES] Presentation has %d slide(s)', len(slides))
  for slide in slides:
    elements = slide.get('pageElements', [])
    for element in elements:
      desc = element.get('description', '')
      if desc:
        logging.info('[SLIDES] Found element with description=%r on slide %s', desc, slide['objectId'])
      if desc.upper() == 'CHART':
        page_id = slide['objectId']
        final_element = element
        break
    if final_element:
      break

  bucket_name = get_secret('image_bucket')
  image_name = request_data['image_name']
  image_location = f'https://storage.googleapis.com/{bucket_name}/{image_name}'
  logging.info('[SLIDES] GCS bucket=%s  image_name=%s', bucket_name, image_name)
  logging.info('[SLIDES] Image URL for Slides API: %s', image_location)

  logging.info('[SLIDES] CHART element found: %s (page_id=%s)', bool(final_element), page_id)

  add_img = {
    'createImage': {
      'objectId': 'my_id',
      'url': image_location,
      'elementProperties': {
        'pageObjectId': page_id,
        'size': {},
        'transform': {},
      },
    }
  }
  if final_element:
    add_img['createImage']['elementProperties']['size'] = final_element['size']
    add_img['createImage']['elementProperties']['transform'] = final_element[
      'transform'
    ]
    requests.append(add_img)
    logging.info('[SLIDES] createImage request appended')
  else:
    logging.warning('[SLIDES] No element with description=CHART found — chart image will NOT be inserted')

  logging.info('[SLIDES] Sending batchUpdate with %d request(s)', len(requests))
  try:
    result = slides_service.presentations().batchUpdate(
      body={'requests': requests}, presentationId=slide_copy_id).execute()
    replies = result.get('replies', [])
    logging.info('[SLIDES] batchUpdate succeeded: replies=%d', len(replies))
    for i, reply in enumerate(replies):
      logging.info('[SLIDES] reply[%d]: %s', i, list(reply.keys()) if reply else '(empty)')
  except Exception as e:
    logging.exception('[SLIDES] batchUpdate failed for slide %s: %s', slide_copy_id, e)
    return 'Slides error'

  logging.info('[SLIDES] create_slide complete: returning slide_copy_id=%s', slide_copy_id)
  return slide_copy_id
